#!/bin/bash

export GOPATH=$HOME/golang
export PATH=$PATH:$GOPATH/bin

function usage {
	echo "$0 [options]"
	echo "all options are mandatory"
	echo -e "--maas-ip\t\t\t - MaaS IP address"
	echo -e "--state-machine-tag\t\t - The tag added in MaaS for the state machine. Mandatory if --no-bootstrap is ommited"
	echo -e "--no-bootstrap\t\t\t - Do not bootstrap the juju state machine"
	exit 0
}

[ $# -eq 0 ] && usage

while [ $# -gt 0 ]
do
	case $1 in --maas-ip)
			MAAS_IP=$2
			shift;;
		--state-machine-tag)
			STATE_TAG=$2
			shift;;
		--no-bootstrap)
			NO_BOOTSTRAP=1;;
		*)
			usage;;
		esac
	shift
done 

[ -z $MAAS_IP ] && usage
if [ -z $NO_BOOTSTRAP ]
then
	[ -z $STATE_TAG ] && usage
fi

function check_error {
	if [ $? -ne 0 ]
	then
		echo $1
		exit 1
	fi
}

function install_prereq {
	sudo apt-get update
	check_error "FAILED to update sources"
	sudo apt-get -y install golang-go git mercurial bzr
	check_error "FAILED to install prerequisites"
}

function generate_maas_key {
	cd "$HOME/maas"
	./bin/maas-region-admin apikey --generate --username root
	check_error "FAILED to install prerequisites"
}

function set_vars {
	echo "export GOPATH=$HOME/golang" >> ~/.bashrc
	echo 'export PATH=$PATH:$GOPATH/bin' >> ~/.bashrc
	mkdir -p $GOPATH
}

function get_juju {
	go get -v launchpad.net/juju-core/...
	rm -rf $GOPATH/src/launchpad.net/juju-core
	git clone git@github.com:cloudbase/juju-core.git $GOPATH/src/launchpad.net/juju-core
	check_error "FAILED to get get patchet juju"
	cd $GOPATH/src/launchpad.net/juju-core && git checkout rebase-1.19
	check_error "FAILED to checkout 1.19 branch"
	cd $GOPATH/src/code.google.com/p/go.crypto/ssh && hg update -r 191:2990fc550b9f # hack for this particular checkout of juju
	check_error "FAILED to revert to revision 191:2990fc550b9f"
}

function install_juju {
	go install -v launchpad.net/juju-core/...
	check_error "FAILED to install juju"
}

function init_juju {
	juju init
	check_error "FAILED to init juju"
	MAAS_KEY=$(generate_maas_key)
	sed -i 's/^default:.*/default: maas/g' $HOME/.juju/environments.yaml
	sed -i 's|maas-server: .*|maas-server: "http://'$MAAS_IP':5240/"|' $HOME/.juju/environments.yaml
	sed -i 's|maas-oauth: .*|maas-oauth: "'$MAAS_KEY'"|' $HOME/.juju/environments.yaml
}

function create_tools {
	mkdir -p $HOME/.juju/tools/releases
	pushd $HOME/.juju/tools/releases
	cp ~/golang/bin/jujud .
	tar -czf juju-1.19.1-trusty-amd64.tgz jujud
	rm jujud
	cp juju-1.19.1-trusty-amd64.tgz juju-1.19.1-precise-amd64.tgz
	popd
	juju-metadata generate-tools
}

function bootstrap_juju {
	sed -i '1i nameserver '$MAAS_IP'' /etc/resolv.conf
	juju sync-tools --source=$HOME/.juju/ --debug
	juju bootstrap --debug --constraints tags=$STATE_TAG
}

install_prereq
set_vars
get_juju
install_juju
init_juju
create_tools

[ -z $NO_BOOTSTRAP ] && bootstrap_juju