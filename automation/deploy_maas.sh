#!/bin/bash

#param: EXT_NIC
#param: INT_NIC
#param: INT_NET
#param: SAMBA_SHARE
#param: LAUNCHPAD_LOGIN

export PYTHONPATH="/home/$USER/maas/etc:/home/$USER/maas/src"
export PATH="$PATH:/home/$USER/maas/bin:/home/$USER/maas/scripts"

function usage {
	echo "$0 [options]"
	echo "all options are mandatory"
	echo -e "--ext-nic\t\t - External network interface card"
	echo -e "--int-nic\t\t - Internal network interface card"
	echo -e "--int-net\t\t - Internal network address"
	echo -e "--samba\t\t\t - Path to samba share for windows sources"
	echo -e "--lp-login\t\t - launchpad login"
	exit 0
}

[ $# -eq 0 ] && usage

while [ $# -gt 0 ]
do
	case $1 in --ext-nic)
			EXT_NIC=$2
			shift;;
		--int-nic)
			INT_NIC=$2
			shift;;
		--int-net)
			INT_NET=$2
			shift;;
		--samba)
			SAMBA_SHARE=$2
			shift;;
		--lp-login)
			LAUNCHPAD_LOGIN=$2
			shift;;
		*)
			usage;;
		esac
	shift
done 

[ -z $EXT_NIC ] && usage
[ -z $INT_NIC ] && usage
[ -z $INT_NET ] && usage
[ -z $SAMBA_SHARE ] && usage
[ -z $LAUNCHPAD_LOGIN ] && usage

WINPESAMBASHARE=/var/lib/maas/winpe

function check_error {
	if [ $? -ne 0 ]
	then
		echo $1
		exit 1
	fi
}

function ssh_config {
	if [ ! -d "$HOME/.ssh" ]
	then
		mkdir "$HOME/.ssh"
		chmod 700 "$HOME/.ssh"
	fi
	tee -a "$HOME/.ssh/config" <<EOF

ForwardAgent    yes
StrictHostKeyChecking no
UserKnownHostsFile /dev/null
GSSAPIAuthentication no
EOF
}

function get_nic_ip {
	if [ -z "$1" ]
	then
		echo "No NIC given"
		exit 1
	fi
	IP=$(ifconfig $1 | grep "inet addr:" | sed 's/.*inet addr://;s/ .*//g')
	echo $IP
}

function get_nic_mask {
	if [ -z "$1" ]
	then
		echo "No NIC given"
		exit 1
	fi
	MASK=$(ifconfig $1 | grep "Mask:" | sed 's/.*Mask://')
	echo $MASK
}

EXT_IP=$(get_nic_ip $EXT_NIC)
INT_NIC_MASK=$(get_nic_mask $INT_NIC)

if [ -z "$EXT_IP" ]
then
	echo "Could not get external IP"
	exit 1
fi

function add_myself_to_sudoers {
	sudo -n echo "I have the power!" > /dev/null 2>&1
	if [ $? -ne 0 ]
	then
		echo  "$USER ALL=NOPASSWD: ALL" | sudo tee -a /etc/sudoers.d/$USER
		sudo chmod 440 /etc/sudoers.d/$USER
	fi
}

function install_prerequisites {
	echo "Installing prerequisites"
	sudo apt-get install -y bzr git mercurial make squid-deb-proxy authbind maas-dhcp samba expect
}

function get_maas {
	bzr launchpad-login $LAUNCHPAD_LOGIN
	bzr branch lp:~gabriel-samfira/maas/cloudbase-windows-support-faster-cloudbaseinit-download "$HOME/maas"
}

function setup_env {
	mkdir -p ~/.buildout/cache
cat << EOF > ~/.buildout/default.cfg
[buildout]
download-cache = /home/$USER/.buildout/cache
eggs-directory = /home/$USER/.buildout/eggs
EOF

	if [ ! -d "$HOME/maas" ]
	then
		get_maas
		check_error "ERROR: Failed to get MaaS"
	fi
	cd "$HOME/maas"
	make install-dependencies
	make
	make syncdb

	sudo tee -a /etc/tgt/targets.conf << EOF
include /var/lib/maas/boot-resources/current/maas.tgt
EOF
	check_error "ERROR: Failed to write iscsi config"

	cat << EOF >> ~/.bashrc

export PYTHONPATH="/home/$USER/maas/etc:/home/$USER/maas/src"
export PATH="$PATH:/home/$USER/maas/bin:/home/$USER/maas/scripts"
EOF

	sudo touch /etc/authbind/byport/68
	sudo touch /etc/authbind/byport/53
	sudo touch /etc/authbind/byport/69
	sudo chmod +x /etc/authbind/byport/*

	sudo ln -s /var/lib/maas/dhcp/dhcpd.leases $HOME/maas/run/dhcpd.leases
	check_error "ERROR: Failed to create dhcpd.leases symlink"
	sudo ln -s $HOME/maas/etc/maas /etc/maas
	check_error "ERROR: Failed to create /etc/maas symlink"

	sed -i s/port:\ 5244/port:\ 69/g $HOME/maas/etc/maas/pserv.yaml
	sudo mkdir /var/lib/maas
	check_error "ERROR: Failed to create /var/lib/maas"

	if [ -z "$INT_NIC" ]
	then
		echo "No internal nic specified"
		exit 1
	fi

	sudo sh -c "echo $INT_NIC > /var/lib/maas/dhcpd-interfaces"
	sed -i 's|MAAS_URL\=\"http://0.0.0.0:5240/\"|MAAS_URL\=\"http://'$EXT_IP':5240/\"|g' $HOME/maas/etc/demo_maas_cluster.conf
	sed -i "s/listen-on port {{port}} {127.0.0.1;};/listen-on port {{port}} {any;};/g" $HOME/maas/src/provisioningserver/testing/bindfixture.py
	sudo service postgresql stop
	sudo update-rc.d -f postgresql remove
	sudo service bind9 stop
	sudo update-rc.d -f bind9 remove

	sed -i '/.*debug_toolbar.*/ s/^/#/' src/maas/development.py
	sed -i '/.*debug_toolbar.*/ s/^/#/' src/maas/demo.py

	sudo sed -i s/port=5246/port=53/g "$HOME/maas/services/dns/run"
}


function add_secure_path {
	source $HOME/.bashrc
	echo -e "\nDefaults:$USER secure_path=$PATH\n" | sudo tee -a /etc/sudoers.d/$USER
	echo -e "\nDefaults:$USER env_keep += PYTHONPATH\n" | sudo tee -a /etc/sudoers.d/$USER
}

function setup_samba {
	sudo mkdir -p $WINPESAMBASHARE
	sudo chown -R $USER.$USER $WINPESAMBASHARE  

	sudo tee -a /etc/samba/smb.conf <<EOF

[winpe]
  comment = Windows installation share
  writable = yes
  locking = no
  path = $WINPESAMBASHARE
  public = yes
  guest ok = yes
  browseable = yes

EOF
	sudo service smbd restart
}

function set_samba_server {
	INT_IP=$(get_nic_ip $INT_NIC)
	tee -a $HOME/maas/etc/maas/pserv.yaml <<EOF

windows:
  ## Windows installation support requires that a SAMBA share be setup. The
  ## share holds the installation files that Windows needs to perform the
  ## installation.
  remote_path: \\\\$INT_IP\\winpe
EOF
}

function disable_apparmor_for_dhcp {
	sudo ln -s /etc/apparmor.d/usr.sbin.dhcpd /etc/apparmor.d/disable/usr.sbin.dhcpd
	sudo /etc/init.d/apparmor restart
}

function add_module {
    sudo /sbin/modprobe $1
    echo $1 | sudo tee /etc/modules
}

function setup_ufw {
	# Optional: in case you'd like to reset any existing rule:
	sudo ufw --force reset 

	sudo sed -i 's/^DEFAULT_FORWARD_POLICY=.*$/DEFAULT_FORWARD_POLICY="ACCEPT"/g' /etc/default/ufw

	sudo sed -i 's/^#net\/ipv4\/ip_forward=.*$/net\/ipv4\/ip_forward=1/g' /etc/ufw/sysctl.conf
	sudo sed -i 's/^#net\/ipv6\/conf\/default\/forwarding=.*$/net\/ipv6\/conf\/default\/forwarding=1/g' /etc/ufw/sysctl.conf

	sudo sed -i "s/^# Don't delete these required lines, otherwise there will be errors$/*nat\n:POSTROUTING ACCEPT \  [0:0\]\n-A POSTROUTING -s $INT_NET\/$INT_NIC_MASK -o $EXT_NIC -j MASQUERADE\nCOMMIT\n\n# Don't delete these required lines, otherwise there will be errors\n/g" /etc/ufw/before.rules

	add_module ip_tables
	add_module nf_conntrack
	add_module nf_conntrack_ftp
	add_module nf_conntrack_irc
	add_module iptable_nat
	add_module nf_nat_ftp

	# SSH
	sudo ufw allow 22
	# MaaS
	sudo ufw allow 5240

	# On $INT_NIC only

	#DHCP
	sudo ufw allow in on $INT_NIC proto udp to any port 67
	#DNS
	sudo ufw allow 53
	sudo ufw allow 5247
	sudo ufw allow 7911
	#SAMBA
	sudo ufw allow 445
	sudo ufw allow 139
	#TFTP
	sudo ufw allow in on $INT_NIC proto udp to any port 69
	# HTTP / HTTPS
	sudo ufw allow in on $INT_NIC proto tcp to any port 80
	sudo ufw allow in on $INT_NIC proto tcp to any port 443  
	#iSCSI
	sudo ufw allow in on $INT_NIC proto tcp to any port 3260
	# squid
	sudo ufw allow in on $INT_NIC proto tcp to any port 8000

	sudo ufw disable && sudo sudo ufw --force enable
	sudo /sbin/sysctl -p
}

function install_esxi_power_adapter {
	git clone https://github.com/trobert2/maas-hacks.git /tmp/maas-hacks
	check_error "ERROR: Failed to clone maas-hacks repo"
	pushd /tmp/maas-hacks/vmware
	git checkout remotes/origin/new_poweradapter
	chmod +x install.sh
	./install.sh
	popd
}

function fix_tftp {
	pushd /usr/share/pyshared/
	sudo rm -rf tftp
	git clone https://github.com/shylent/python-tx-tftp.git ~/tftp
	sudo cp -a ~/tftp/tftp .
	popd
	pushd /usr/lib/python2.7/dist-packages/tftp
	sudo rm *.pyc
	popd
}

function run_maas_in_background {
	pushd "$HOME/maas"
	source ~/.bashrc; make start
	popd
}

function create_superuser {
	pushd "$HOME/maas"
	expect <<EOD
spawn ./bin/maas-region-admin createsuperuser --username root --email root@local.host
expect "Password:"
send "Passw0rd\n"
expect "Password (again):"
send "Passw0rd\n"
expect eof
EOD
}

function wait_for_maas {
	count=0
	while true
	do
		nc -z 127.0.0.1 5240
		[ $? -eq 0 ] && return 0
		sleep 5
		[ $count -ge 10 ] && break
		count=$(($count + 1))
	done
	echo "MaaS Failed to start in 50 seconds"
	exit 1

}

function import_pxe_images {
	source ~/.bashrc; sudo maas-import-pxe-files
}

function get_maas_api_key {
	cd "$HOME/maas"
	./bin/maas-region-admin apikey --username root
	cd -
}

function do_maas_login {
	MAAS_KEY=$(get_maas_api_key)
	pushd "$HOME/maas"
	expect <<EOD
spawn ./bin/maas login dev http://$EXT_IP:5240
expect "API key (leave empty for anonymous access):"
send "$MAAS_KEY\n"
expect eof
EOD
	popd
}

function get_cluster_uuid {
	cd "$HOME/maas"
	./bin/maas dev node-groups list | grep uuid | sed 's/.*: "//;s/".*//g'
}

function wait_for_uuid {
	UUID=$(get_cluster_uuid)
	count=0
	while true
	do
		C=$(echo -n $UUID | wc -c)
		if [ $C -eq 36 ]
		then
			echo $UUID
			break
		fi
		count=$(($count + 1))
		if [ $count -ge 20 ]
		then
			echo "FAILED to get cluster UUID"
			exit 1
		fi
		sleep 10
		UUID=$(get_cluster_uuid)
	done
}

function set_private_interface {
	UUID=$(wait_for_uuid)
	pushd "$HOME/maas"
	START_IP=${INT_IP%.*}.100
	STOP_IP=${INT_IP%.*}.200
	echo ./bin/maas dev node-group-interface update $UUID $INT_NIC router_ip=$INT_IP ip_range_low=$START_IP ip_range_high=$STOP_IP management=2
	./bin/maas dev node-group-interface update $UUID $INT_NIC router_ip=$INT_IP ip_range_low=$START_IP ip_range_high=$STOP_IP management=2
	popd
}

function set_upstream_dns {
	pushd "$HOME/maas"
	./bin/maas dev maas set-config name=upstream_dns value=8.8.8.8
	popd
}

ssh_config
add_myself_to_sudoers
install_prerequisites
setup_env
add_secure_path
setup_samba
set_samba_server
disable_apparmor_for_dhcp
setup_ufw
install_esxi_power_adapter
fix_tftp
run_maas_in_background
wait_for_maas
create_superuser
import_pxe_images
do_maas_login
set_private_interface
set_upstream_dns