#!/bin/bash

#    Licensed under the Apache License, Version 2.0 (the "License"); you may
#    not use this file except in compliance with the License. You may obtain
#    a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
#    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
#    License for the specific language governing permissions and limitations
#    under the License.

# devstack/plugin.sh
# Functions to control the configuration and operation of the OVN service

# Dependencies:
#
# ``functions`` file
# ``DEST`` must be defined
# ``STACK_USER`` must be defined

# ``stack.sh`` calls the entry points in this order:
#
# - install_ovn
# - configure_ovn
# - configure_ovn_plugin
# - init_ovn
# - start_ovn
# - stop_ovn
# - cleanup_ovn

# Save trace setting
XTRACE=$(set +o | grep xtrace)
set +o xtrace


# Defaults
# --------

# The git repo to use
OVN_REPO=${OVN_REPO:-https://github.com/openvswitch/ovs.git}
OVN_REPO_NAME=$(basename ${OVN_REPO} | cut -f1 -d'.')

# The project directory
NETWORKING_OVN_DIR=$DEST/networking-ovn

# The branch to use from $OVN_REPO
OVN_BRANCH=${OVN_BRANCH:-origin/master}

# How to connect to ovsdb-server hosting the OVN SB database.
OVN_SB_REMOTE=${OVN_SB_REMOTE:-tcp:$HOST_IP:6642}

# How to connect to ovsdb-server hosting the OVN NB database
OVN_NB_REMOTE=${OVN_NB_REMOTE:-tcp:$HOST_IP:6641}

# A UUID to uniquely identify this system.  If one is not specified, a random
# one will be generated.  A randomly generated UUID will be saved in a file
# 'ovn-uuid' so that the same one will be re-used if you re-run DevStack.
OVN_UUID=${OVN_UUID:-}

# Whether to enable using OVN's L3 functionality. If this value is disabled,
# OpenStack will use q-l3 functionality.
OVN_L3_MODE=$(trueorfalse True OVN_L3_MODE)

# Whether or not to build the openvswitch kernel module from ovs.  This is required
# unless the distro kernel includes ovs+conntrack support.
OVN_BUILD_MODULES=$(trueorfalse True OVN_BUILD_MODULES)

# MTU of the native (underlying) physical network infrastructure. Defaults
# to 1500 bytes.
OVN_NATIVE_MTU=${OVN_NATIVE_MTU:-1500}

# Neutron directory
NEUTRON_DIR=$DEST/neutron

# Set variables for building OVS from source
OVS_REPO=$OVN_REPO
OVS_REPO_NAME=$OVN_REPO_NAME
OVS_BRANCH=$OVN_BRANCH

# Utility Functions
# -----------------

# There are some ovs functions OVN depends on that must be sourced from these
source $TOP_DIR/lib/neutron_plugins/ovs_base
source $TOP_DIR/lib/neutron_plugins/openvswitch_agent

function is_ovn_service_enabled {
    ovn_service=$1
    is_service_enabled ovn && return 0
    is_service_enabled $ovn_service && return 0
    return 1
}


# Entry Points
# ------------

# cleanup_ovn() - Remove residual data files, anything left over from previous
# runs that a clean run would need to clean up
function cleanup_ovn {
    local _pwd=$(pwd)
    cd $DEST/$OVN_REPO_NAME
    sudo make uninstall
    cd $_pwd
}

# configure_ovn() - Set config files, create data dirs, etc
function configure_ovn {
    echo "Configuring OVN"

    if [ -z "$OVN_UUID" ] ; then
        if [ -f ./ovn-uuid ] ; then
            OVN_UUID=$(cat ovn-uuid)
        else
            OVN_UUID=$(uuidgen)
            echo $OVN_UUID > ovn-uuid
        fi
    fi
}

function configure_ovn_plugin {
    echo "Configuring Neutron for OVN"

    if is_service_enabled q-svc ; then
        # NOTE(arosen) needed for tempest
        export NETWORK_API_EXTENSIONS=$(python -c \
            'from networking_ovn.common import extensions ;\
             print ",".join(extensions.SUPPORTED_API_EXTENSIONS)')


        iniset $NEUTRON_CONF DEFAULT core_plugin "$Q_PLUGIN_CLASS"
        iniset $NEUTRON_CONF DEFAULT service_plugins "qos"
        iniset $Q_PLUGIN_CONF_FILE ovn ovsdb_connection "$OVN_NB_REMOTE"
        iniset $Q_PLUGIN_CONF_FILE ovn ovn_l3_mode "$OVN_L3_MODE"
    fi

    if is_service_enabled q-l3 ; then
        if [[ "$OVN_L3_MODE" == "True" ]]; then
            die $LINENO "The q-l3 service must be disabled with OVN_L3_MODE set to True."
        fi
    fi

    if is_service_enabled q-dhcp ; then
        #
        # Similar to other virtual networking mechanisms, OVN implements
        # overlay networks among nodes running OVS. Overlay network protocols
        # add overhead that effectively reduces the MTU available to
        # instances. MTU disparities can lead to packet loss and performance
        # issues.
        #
        # Calculate MTU for self-service/private networks accounting for
        # GENEVE overlay protocol overhead of 58 bytes and configure the
        # DHCP agent to provide it to instances. Only effective on neutron
        # subnets with DHCP.
        #
        # TODO (mkassawara): Temporary workaround for larger MTU problems
        # in neutron. Ideally, provider networks should use the native
        # (underlying) physical network infrastructure MTU.

        iniset $Q_DHCP_CONF_FILE DEFAULT dnsmasq_config_file "/etc/neutron/dnsmasq.conf"
        if ! grep "dhcp-option=26" /etc/neutron/dnsmasq.conf ; then
            echo "dhcp-option=26,$(($OVN_NATIVE_MTU - 58))" | sudo tee -a /etc/neutron/dnsmasq.conf
        fi
    fi
}

# init_ovn() - Initialize databases, etc.
function init_ovn {
    # clean up from previous (possibly aborted) runs
    # create required data files

    # Assumption: this is a dedicated test system and there is nothing important
    # in the ovn, ovn-nb, or ovs databases.  We're going to trash them and
    # create new ones on each devstack run.

    base_dir=$DATA_DIR/ovs
    mkdir -p $base_dir

    for db in conf.db ovnsb.db ovnnb.db ; do
        if [ -f $base_dir/$db ] ; then
            rm -f $base_dir/$db
        fi
    done
    rm -f $base_dir/.*.db.~lock~

    echo "Creating OVS, OVN-Southbound and OVN-Northbound Databases"
    ovsdb-tool create $base_dir/conf.db $DEST/$OVN_REPO_NAME/vswitchd/vswitch.ovsschema
    if is_ovn_service_enabled ovn-northd ; then
        ovsdb-tool create $base_dir/ovnsb.db $DEST/$OVN_REPO_NAME/ovn/ovn-sb.ovsschema
        ovsdb-tool create $base_dir/ovnnb.db $DEST/$OVN_REPO_NAME/ovn/ovn-nb.ovsschema
    fi
}

# install_ovn() - Collect source and prepare
function install_ovn {
    echo "Installing OVN and dependent packages"

    # If OVS is already installed, remove it, because we're about to re-install
    # it from source.
    for package in openvswitch openvswitch-switch openvswitch-common; do
        if is_package_installed $package ; then
            uninstall_package $package
        fi
    done

    if ! is_neutron_enabled ; then
        # networking-ovn depends on neutron, so ensure it at least gets
        # installed.
        install_neutron
    fi

    setup_package $DEST/networking-ovn
    # Install tox, used to generate the config (see devstack/override-defaults)
    pip_install tox
    source $NEUTRON_DIR/devstack/lib/ovs
    compile_ovs $OVN_BUILD_MODULES
    sudo chown $(whoami) /usr/local/var/run/openvswitch
    sudo chown $(whoami) /usr/local/var/log/openvswitch
}

function start_ovs {
    echo "Starting OVS"

    local _pwd=$(pwd)

    local ovsdb_logfile="ovsdb-server.log.${CURRENT_LOG_TIME}"
    bash -c "cd '$LOGDIR' && touch '$ovsdb_logfile' && ln -sf '$ovsdb_logfile' ovsdb-server.log"

    local ovsdb_nb_logfile="ovsdb-server-nb.log.${CURRENT_LOG_TIME}"
    bash -c "cd '$LOGDIR' && touch '$ovsdb_nb_logfile' && ln -sf '$ovsdb_nb_logfile' ovsdb-server-nb.log"

    local ovsdb_sb_logfile="ovsdb-server-sb.log.${CURRENT_LOG_TIME}"
    bash -c "cd '$LOGDIR' && touch '$ovsdb_sb_logfile' && ln -sf '$ovsdb_sb_logfile' ovsdb-server-sb.log"

    cd $DATA_DIR/ovs

    EXTRA_DBS=""
    OVSDB_SB_REMOTE=""
    if is_ovn_service_enabled ovn-northd ; then

        # TODO (regXboi): change ovn-ctl so that we can use something
        # other than --db-nb-port for port and ip address
        DB_NB_PORT="6641:$HOST_IP"
        DB_NB_SOCK="/usr/local/var/run/openvswitch/nb_db.sock"
        DB_NB_PID="/usr/local/var/run/openvswitch/ovsdb-server-nb.pid"
        DB_NB_FILE="$DATA_DIR/ovs/ovnnb.db"
        OVN_NB_LOGFILE="$LOGDIR/ovsdb-server-nb.log"

        # TODO (regXboi): change ovn-ctl so that we can use something
        # other than --db-sb-port for port and ip address
        DB_SB_PORT="6642:$HOST_IP"
        DB_SB_SOCK="/usr/local/var/run/openvswitch/sb_db.sock"
        DB_SB_PID="/usr/local/var/run/openvswitch/ovsdb-server-sb.pid"
        DB_SB_FILE="$DATA_DIR/ovs/ovnsb.db"
        OVN_SB_LOGFILE="$LOGDIR/ovsdb-server-sb.log"

        /usr/local/share/openvswitch/scripts/ovn-ctl start_ovsdb \
              --db-nb-port=$DB_NB_PORT --db-nb-sock=$DB_NB_SOCK \
              --db-nb-pid=$DB_NB_PID --db-nb-file=$DB_NB_FILE \
              --ovn-nb-logfile=$OVN_NB_LOGFILE --db-sb-port=$DB_SB_PORT \
              --db-sb-sock=$DB_SB_SOCK --db-sb-pid=$DB_SB_PID \
              --db-sb-file=$DB_SB_FILE --ovn-sb-logfile=$OVN_SB_LOGFILE

        echo "Waiting for ovn ovsdb servers to start ... "
        local testcmd="test -e $DB_NB_SOCK -a -e $DB_SB_SOCK"
        test_with_retry "$testcmd" "nb ovsdb-server did not start" $SERVICE_TIMEOUT 1
        echo "done."
    fi

    # TODO (regXboi): it would be nice to run the following with run_process
    # and have it end up under the control of screen.  However, at the point
    # this is called, screen isn't running, so we'd have to overload
    # USE_SCREEN to get the process to start, but testing shows that the
    # resulting process doesn't want to create br-int, which leaves things
    # rather broken.  So, stay with this for now and somebody more tenacious
    # than I can figure out how to make it work...

    if is_ovn_service_enabled ovn-controller; then
        ovsdb-server --remote=punix:/usr/local/var/run/openvswitch/db.sock \
                     --remote=db:Open_vSwitch,Open_vSwitch,manager_options \
                     --pidfile --detach -vconsole:off \
                     --log-file=$LOGDIR/ovsdb-server.log \
                     conf.db

        echo -n "Waiting for ovsdb-server to start ... "
        local testcmd="test -e /usr/local/var/run/openvswitch/db.sock"
        test_with_retry "$testcmd" "ovsdb-server did not start" $SERVICE_TIMEOUT 1
        echo "done."
        ovs-vsctl --no-wait init
        ovs-vsctl --no-wait set open_vswitch . system-type="devstack"
        ovs-vsctl --no-wait set open_vswitch . external-ids:system-id="$OVN_UUID"
    fi

    if is_ovn_service_enabled ovn-controller ; then
        ovs-vsctl --no-wait set open_vswitch . external-ids:ovn-remote="$OVN_SB_REMOTE"
        ovs-vsctl --no-wait set open_vswitch . external-ids:ovn-bridge="br-int"
        ovs-vsctl --no-wait set open_vswitch . external-ids:ovn-encap-type="geneve"
        ovs-vsctl --no-wait set open_vswitch . external-ids:ovn-encap-ip="$HOST_IP"

        _neutron_ovs_base_setup_bridge br-int
        ovs-vsctl --no-wait set bridge br-int fail-mode=secure other-config:disable-in-band=true

        local ovswd_logfile="ovs-switchd.log.${CURRENT_LOG_TIME}"
        bash -c "cd '$LOGDIR' && touch '$ovswd_logfile' && ln -sf '$ovswd_logfile' ovs-vswitchd.log"

        # Bump up the max number of open files ovs-vswitchd can have
        sudo sh -c "ulimit -n 32000 && exec ovs-vswitchd --pidfile --detach -vconsole:off --log-file=$LOGDIR/ovs-vswitchd.log"
    fi

    cd $_pwd
}

# start_ovn() - Start running processes, including screen
function start_ovn {
    echo "Starting OVN"

    if is_ovn_service_enabled ovn-controller ; then
        # (regXboi) pulling out --log-file to avoid double logging
        # appears to break devstack, so let's not do that
        run_process ovn-controller "sudo ovn-controller --pidfile --log-file unix:/usr/local/var/run/openvswitch/db.sock"

        # This makes sure that the console logs have time stamps to
        # the millisecond, but we need to make sure ovs-appctl has
        # a pid file to work with, so ...
        echo -n "Waiting for ovn-controller to start ... "
        local testcmd="test -e /usr/local/var/run/openvswitch/ovn-controller.pid"
        test_with_retry "$testcmd" "ovn-controller did not start" $SERVICE_TIMEOUT 1
        echo "done."
        sudo ovs-appctl -t ovn-controller vlog/set "PATTERN:CONSOLE:%D{%Y-%m-%dT%H:%M:%S.###Z}|%05N|%c%T|%p|%m"
    fi

    if is_ovn_service_enabled ovn-northd ; then

        DB_NB_PID="/usr/local/var/run/openvswitch/ovsdb-server-nb.pid"
        DB_NB_SOCK="/usr/local/var/run/openvswitch/nb_db.sock"
        DB_SB_PID="/usr/local/var/run/openvswitch/ovsdb-server-sb.pid"
        DB_SB_SOCK="/usr/local/var/run/openvswitch/sb_db.sock"
        # TODO (regXboi): change ovn-ctl so that we can just use
        # OVN_NORTHD_LOG=$LOGDIR/ovn-northd.log here
        OVN_NORTHD_LOG="--log-file=$LOGDIR/ovn-northd.log"

        NORTHD_CMD= /usr/local/share/openvswitch/scripts/ovn-ctl start_northd \
            --db-nb-sock=$DB_NB_SOCK --db-sb-sock=$DB_SB_SOCK \
            --db-nb-pid=$DB_NB_PID --db-sb-pid=$DB_SB_PID \
            --ovn-northd-log=$OVN_NORTHD_LOG

        run_process ovn-northd "$NORTHD_CMD"

        # This makes sure that the console logs have time stamps to
        # the millisecond, but we need to make sure ovs-appctl has
        # a pid file to work with, so ...
        echo -n "Waiting for ovn-northd to start ... "
        local testcmd="test -e /usr/local/var/run/openvswitch/ovn-northd.pid"
        test_with_retry "$testcmd" "ovn-northd did not start" $SERVICE_TIMEOUT 1
        echo "done."
        sudo ovs-appctl -t ovn-northd vlog/set "PATTERN:CONSOLE:%D{%Y-%m-%dT%H:%M:%S.###Z}|%05N|%c%T|%p|%m"
    fi
}

# stop_ovn() - Stop running processes (non-screen)
function stop_ovn {
    if is_ovn_service_enabled ovn-controller ; then
        stop_process ovn-controller
        sudo killall ovs-vswitchd
    fi
    if is_ovn_service_enabled ovn-northd ; then
        /usr/local/share/openvswitch/scripts/ovn-ctl stop_northd
    fi
    sudo killall ovsdb-server
}

# stop_ovs_dp() - Stop OVS datapath
function stop_ovs_dp {
    sudo ovs-dpctl dump-dps | sudo xargs -n1 ovs-dpctl del-dp
    sudo rmmod vport_geneve
    sudo rmmod openvswitch
}

function disable_libvirt_apparmor {
    if ! sudo aa-status --enabled ; then
        return 0
    fi
    # NOTE(arosen): This is used as a work around to allow newer versions
    # of libvirt to work with ovs configured ports. See LP#1466631.
    # requires the apparmor-utils
    install_package apparmor-utils
    # disables apparmor for libvirtd
    sudo aa-complain /etc/apparmor.d/usr.sbin.libvirtd
}

# main loop
if is_service_enabled q-svc || is_ovn_service_enabled ovn-northd || is_ovn_service_enabled ovn-controller; then
    if [[ "$1" == "stack" && "$2" == "install" ]]; then
        if [[ "$OFFLINE" != "True" ]]; then
            install_ovn
        fi
        configure_ovn
        init_ovn
        # We have to start at install time, because Neutron's post-config
        # phase runs ovs-vsctl.
        start_ovs
        disable_libvirt_apparmor
    elif [[ "$1" == "stack" && "$2" == "post-config" ]]; then
        configure_ovn_plugin

        if is_service_enabled nova; then
            create_nova_conf_neutron
        fi

        start_ovn

        # If not previously set by another process, set the OVN_*_DB
        # variables to enable OVN commands from any node.
        grep -lq 'OVN' ~/.bash_profile || echo -e "\n# Enable OVN commands from any node.\nexport OVN_NB_DB=$OVN_REMOTE\nexport OVN_SB_DB=$OVN_REMOTE" >> ~/.bash_profile

    fi

    if [[ "$1" == "unstack" ]]; then
        stop_ovn
        stop_ovs_dp
        cleanup_ovn
    fi
fi

# Restore xtrace
$XTRACE

# Tell emacs to use shell-script-mode
## Local variables:
## mode: shell-script
## End:
