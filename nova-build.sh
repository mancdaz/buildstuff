#!/bin/bash

set -e
#set -x
set -u

if [ -f  ~/.nova-opencloud-uk ]; then
    . ~/.nova-opencloud-uk
fi

RHEL_IMAGE="a2723606-19bc-43db-900c-2b1f40423883"
CENT_IMAGE="ebe9d6c3-3d83-4aba-849e-5211302582df"
#UBUN_IMAGE="cab803a5-c8ed-4c41-9113-20e5cd0a04c3" # chef10
UBUN_IMAGE="dcff35db-55d8-452e-8e2e-ff7342e6c25b" # chef11
BANJONET="59357aab-2ef1-4937-8baa-7a3bef1333a6"

OS=${OS:-"ubun"}

FLAVOR_1G_ID=${FLAVOR_1G_ID:-3}
FLAVOR_2G_ID=${FLAVOR_2G_ID:-4}
FLAVOR_4G_ID=${FLAVOR_4G_ID:-5}
SSH_OPTS="-q -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i ~/.ssh/cloud_id_rsa "
KNIFE_CONFIG=${KNIFE_CONFIG:-"~/.chef/knife.rb"}

COMPUTE_NODE1_NAME=${PROXY_NODE_NAME:-"${OS}-compute1.rcbops.me"}

RUNLIST=''
ESSEX_FINAL_FULL_RUNLIST=("role[single-controller]" "role[single-compute]" "role[collectd-server]" "role[collectd-client]" "role[graphite]")
FOLSOM_FULL_RUNLIST=("role[single-controller-cinder]" "role[single-compute]" "role[collectd-server]" "role[collectd-client]" "role[graphite]")
BUILD_NEW=false
FULL=false
EMPTY=false
RUN_CHEF=false
PACKAGE_COMPONENT=${PACKAGE_COMPONENT:-folsom}
DELETE_SERVER=false
ENVIRONMENT=''
CHEF=''



##########################
# process arguments      #
##########################

while [ $# -gt 0 ] ; do
    case $1 in
        -p) PACKAGE_COMPONENT=$2 ; shift 2 ;;
        -f) FULL=true ; shift ;;
        -n) EMPTY=true ; shift ;;
        -c) RUN_CHEF=true ; shift ;;
        -b) BUILD_NEW=true ; shift ;;
        -h) CONTROLLER_NODE_NAME=$2 ; shift 2 ;;
        -d) DELETE_SERVER=true ; CONTROLLER_NODE_NAME=${CONTROLLER_NODE_NAME:-$2} ;shift ;;
        -o) OS=$2 ; shift 2 ;;
        -r) RUNLIST=$2 ; shift 2 ;;
        -e) ENVIRONMENT=$2 ; shift 2 ;;
        -v) CHEF=$2 ; shift 2 ;;
        *) shift ;;
    esac
done

if [ ! -z "${RUNLIST}" ]; then
    echo "runlist will be set to: $RUNLIST"
fi

# lowercase for hostname due to weird chef recipe issue (mysql database)
OS=$(echo ${OS} | tr '[A-Z]' '[a-z]')
case $OS in
    "rhel") COMPUTE_IMAGE="${RHEL_IMAGE}" && CONTROLLER_IMAGE="${RHEL_IMAGE}" ;;
    "cent") COMPUTE_IMAGE="${CENT_IMAGE}" && CONTROLLER_IMAGE="${CENT_IMAGE}" ;;
    "ubun") COMPUTE_IMAGE="${UBUN_IMAGE}" && CONTROLLER_IMAGE="${UBUN_IMAGE}" ;;
esac

CONTROLLER_NODE_NAME="${CONTROLLER_NODE_NAME:-${OS}.${PACKAGE_COMPONENT}.com}"
echo "using hostname:      $CONTROLLER_NODE_NAME"

if [ -z ${ENVIRONMENT} ]; then
    #ENVIRONMENT="testing-${OS}-${PACKAGE_COMPONENT}"
    ENVIRONMENT="chef11"
fi

if [ -z ${CHEF} ]; then
    CHEF='LATEST'
fi

echo "using environment:   ${ENVIRONMENT}"

echo "using release:       ${PACKAGE_COMPONENT}"
host_list=( $CONTROLLER_NODE_NAME )


if [ "${PACKAGE_COMPONENT}" != "essex-final" ] && [ "${PACKAGE_COMPONENT}" != "folsom" ]; then
    echo "you didn't choose a valid openstack release: essex or folsom please"
    exit 1
fi


##########################
# functions              #
##########################

function set_env {
    current_env=$(knife node show -c ${KNIFE_CONFIG} $CONTROLLER_NODE_NAME|grep 'Environment'|cut -d':' -f2|cut -d' ' -f2)
    while [ "${current_env}" != "${ENVIRONMENT}" ] ; do
        knife exec -c ${KNIFE_CONFIG} -E "nodes.transform('name:${CONTROLLER_NODE_NAME}') { |n| n.chef_environment('${ENVIRONMENT}');n.save }"
        current_env=$(knife node show -c ${KNIFE_CONFIG} $CONTROLLER_NODE_NAME|grep 'Environment'|cut -d':' -f2|cut -d' ' -f2)
        echo "current environment is $current_env"
        sleep 5
    done
}

function delete_node {
    host=$1

        knife node delete -c ${KNIFE_CONFIG} -y ${host} || true;
        knife client delete -c ${KNIFE_CONFIG} -y ${host} || true;
        for server in $(nova list | grep ${host} | cut -d'|' -f3); do
            echo "deleting ${server} from nova"
            nova delete ${server} || true
        done
}

function run_chef {
    for host in ${host_list[@]}; do

        IP=$(nova show $host |  grep accessIPv4|cut -d'|' -f3 | sed -e 's/ //g')
        # if we haven't been registered yet, do the first run
        exists=$(knife node list -c ${KNIFE_CONFIG} |grep $host || true)
         if [ -z "${exists}" ] ; then
            # load dummy network interface
            ssh $SSH_OPTS root@${IP} modprobe dummy || true
            ssh $SSH_OPTS root@${IP} ifconfig dummy0 up || true
            if [ ${OS} = "rhel" ]; then
                ssh $SSH_OPTS root@${IP} sed -i -e '/Defaults.*requiretty/s/^/#/g' /etc/sudoers
            fi
            # do chef-client first run
            ssh $SSH_OPTS root@${IP} chef-client
            return 0
        fi

        # set environment
        set_env
        #run chef proper
        ssh $SSH_OPTS root@${IP} chef-client || true
    done
    return 0
}

function build_server {

    # remove existing from chef and nova
    for host in ${host_list[@]}; do
        delete_node ${host}
    done
#        knife node delete -c ${KNIFE_CONFIG} -y ${host} || true;
#        knife client delete -c ${KNIFE_CONFIG} -y ${host} || true;
#        for server in $(nova list | grep ${host} | cut -d'|' -f3); do
#            echo "deleting ${server} from nova"
#            nova delete ${server} || true
#        done
#    done

    # spin up the required nodes

    local count=0
    echo "Booting node: ${CONTROLLER_NODE_NAME}"
    nova boot --image ${CONTROLLER_IMAGE} --flavor ${FLAVOR_2G_ID} --nic net-id=${BANJONET} ${CONTROLLER_NODE_NAME}
    while [ "$(nova show ${CONTROLLER_NODE_NAME}|grep status|cut -d'|' -f3|sed -e 's/ //g')" != "ACTIVE" ] ; do
        echo -n "."
        sleep 10
        count=$((count+10))
    done
    echo
    echo "built server in $count seconds"
    echo $count >> ./server_build_timings
}

function remove_runlist {

    host=$1
    echo "emptying runlist for host: $host"
    runlist=$(knife node show -c ${KNIFE_CONFIG} "${host}" | grep -i 'Run list'|cut -d':' -f2 | sed 's/,/ /g')
    runlist+=$(knife node show -c ${KNIFE_CONFIG} "${host}" | grep -i 'Roles'|cut -d':' -f2 | sed 's/,/ /g')
    for role in $( echo "${runlist}" ) ; do knife node run_list remove -c ${KNIFE_CONFIG} "${host}" "${role}" >/dev/null 2>&1 ; done
}

function first_run {

    for host in ${host_list[@]}; do
        exists=$(knife node list -c ${KNIFE_CONFIG} |grep $host || true)
        if [ -z "${exists}" ] ; then
            IP=$(nova show $host |  grep accessIPv4|cut -d'|' -f3 | sed -e 's/ //g')
            # load dummy network interface
            ssh $SSH_OPTS root@${IP} modprobe dummy || true
            ssh $SSH_OPTS root@${IP} ifconfig dummy0 up || true
            # grab swap disk for use by swift
            ssh $SSH_OPTS root@${IP} 'sed -i "/xvdc1/d" /etc/fstab; swapoff /dev/xvdc1; fdisk /dev/xvdc << EOF
d
w
EOF' || true
            BASH_EXTRA_ARGS=""
            if [[ ${CHEF} != "LATEST" ]]; then
                BASH_EXTRA_ARGS="-s - -v ${CHEF_CLIENT_VERSION}"
            fi
            ssh $SSH_OPTS root@${IP} 'curl -skS http://www.opscode.com/chef/install.sh | /bin/bash ${BASH_EXTRA_ARGS}'
            # wait $!


            # keep forgetting to fix the image...
            if [ ${OS} = "rhel" ]; then
                ssh $SSH_OPTS root@${IP} sed -i -e '/Defaults.*requiretty/s/^/#/g' /etc/sudoers
            fi
            # do chef-client first run
            ssh $SSH_OPTS root@${IP} chef-client
            return 0
        fi
    done
}



##########################
# main program           #
##########################

if ${DELETE_SERVER}; then
    delete_node $CONTROLLER_NODE_NAME
    exit 0
fi


${BUILD_NEW} && build_server
first_run


if  $EMPTY  ;  then
    for host in ${host_list[@]}; do remove_runlist "${host}" ; done
    RUNLIST='';
fi

if  $FULL  ; then
    for host in ${host_list[@]} ; do remove_runlist "${host}" ; done
    for host in ${host_list[@]} ; do
        FULL_RUNLIST='role[single-controller],role[single-compute],role[collectd-server],role[collectd-client],role[graphite],recipe[exerstack]'
        knife node run_list add -c ${KNIFE_CONFIG} ${host} ${FULL_RUNLIST}
    done
fi

if [ ! -z $RUNLIST ]; then
    for host in ${host_list[@]} ; do remove_runlist "${host}" ; done
    for host in ${host_list[@]} ; do
        knife node run_list add -c "${KNIFE_CONFIG}" "${host}" "${RUNLIST}"
    done
fi

${RUN_CHEF} && run_chef
