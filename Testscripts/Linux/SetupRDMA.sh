#!/bin/bash
#
# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the Apache License.
# This script will set up RDMA over IB environment.
# To run this script following things are must.
# 1. constants.sh
# 2. All VMs in cluster have infiniband hardware.
# 
# 

########################################################################################################
# Source utils.sh
. utils.sh || {
	echo "Error: unable to source utils.sh!"
	echo "TestAborted" >state.txt
	exit 0
}

# Source constants file and initialize most common variables
UtilsInit

# Constants/Globals
HOMEDIR="/root"

CONSTANTS_FILE="/root/constants.sh"
test_user=lisa
test_password=Skynet@is@c0ming
# find other distro name assignment update
_distro="RHEL"
# find other mpi version assignment update
_support_mpi="ibm"

# functions
Main() {
	# identify VM from constants file
	if [ -e ${CONSTANTS_FILE} ]; then
		source ${CONSTANTS_FILE}
	else
		error_message="missing ${CONSTANTS_FILE} file"
		LogErr "${error_message}"
		SetTestStateFailed
		exit 1
	fi

	# creating rsa key in master
	ssh-keygen -f id_rsa -b 2048 -t rsa -N ''
	mkdir .ssh
	mv id_rsa* .ssh

	# read $slaves and assign each to vm_arr array
	IFS=',' read -r -a vm_arr <<< "$slaves"

	# building trust of passwordless ssh connection among all VMs
	for _vm in "${vm_arr[@]}"; do
		sshpass -p $test_password ssh-copy-id -i .ssh/id_rsa.pub $test_user@$_vm
	done

	# install required packages
	if ( $_distro -eq "RHEL") {
		sudo yum install -y kernel-devel-3.10.0-862.9.1.el7.x86_64 python-devel valgrind-devel
		sudo yum install -y redhat-rpm-config rpm-build gcc-gfortran libdb-devel gcc-c++
		sudo yum install -y glibc-devel zlib-devel numactl-devel libmnl-devel binutils-devel
		sudo yum install -y iptables-devel libstdc++-devel libselinux-devel gcc elfutils-devel
		sudo yum install -y libtool libnl3-devel git java libstdc++.i686
	}

	# remove or disable firewall and selinux services, if needed
	if ( $_distro -eq "RHEL" ) {
		sudo systemctl stop iptables.service
		sudo systemctl disable iptables.service
		sudo systemctl mask firewalld
		sudo systemctl stop firewalld.service
		sudo systemctl disable firewalld.service 
		sudo iptables -nL
		sudo sed -i -e 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config
		# reboot required. TODO.
	}

	# install MPI packages
	wget https://partnerpipelineshare.blob.core.windows.net/mpi/platform_mpi-09.01.04.03r-ce.bin
	chmod +x platform_mpi-09.01.04.03r-ce.bin
	sudo /home/$test_user/platform_mpi-09.01.04.03r-ce.bin
	# Enter, 1, Enter, Enter, Enter, Enter

	# file validation - /opt/ibm/platform_mpi/bin/mpirun


	# install intel MPI benchmark package
	git clone https://github.com/intel/mpi-benchmarks
	cd mpi-benchmark
	

}

# main body

Main