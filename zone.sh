#!/usr/local/bin/bash
if [ $# != 2 ] ;then
    echo "usage $0 node zone"
    exit 1
fi

knife exec -E "nodes.find(:name => '$1') {|n| n.set['swift']['zone'] = '$2'; n.save }"
