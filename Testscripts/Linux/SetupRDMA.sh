#!/bin/bash
#
# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the Apache License.
# This script will set up RDMA over IB environment.
# To run this script following things are must.
# 1. constants.sh
# 2. All VMs in cluster have infiniband hardware.
# 

########################################################################################################
# Source utils.sh
# . utils.sh || {
# 	echo "Error: unable to source utils.sh!"
# 	echo "TestAborted" >state.txt
# 	exit 0
# }

# # Source constants file and initialize most common variables
# UtilsInit

# # Constants/Globals
# HOMEDIR="/root"

# CONSTANTS_FILE="/root/constants.sh"
test_user=lisa
test_password=Skynet@is@c0ming
# mpi_name determines which version of MPI installed. 3 values; ibm, open, intel
mpi_name="ibm"

# find other distro name assignment update
_distro="RHEL"

# debug msg flag
$debug = true

# functions
function DebugMsg {
	if ( $debug ) {
		echo $1
	}
}

function Main() {
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
	DebugMsg "Completed master's RSA ssh key generation"

	# install required packages
	if [ $_distro == "RHEL" ]; then
		echo $test_password | sudo -S yum install -y kernel-devel-3.10.0-862.9.1.el7.x86_64 python-devel valgrind-devel
		echo $test_password | sudo -S yum install -y redhat-rpm-config rpm-build gcc-gfortran libdb-devel gcc-c++
		echo $test_password | sudo -S yum install -y glibc-devel zlib-devel numactl-devel libmnl-devel binutils-devel
		echo $test_password | sudo -S yum install -y iptables-devel libstdc++-devel libselinux-devel gcc elfutils-devel
		echo $test_password | sudo -S yum install -y libtool libnl3-devel git java libstdc++.i686
		DebugMsg "Completed the dependent files installation"
	fi

	# remove or disable firewall and selinux services, if needed
	if [ $_distro == "RHEL" ]; then
		echo $test_password | sudo systemctl stop iptables.service
		echo $test_password | sudo systemctl disable iptables.service
		echo $test_password | sudo systemctl mask firewalld
		echo $test_password | sudo systemctl stop firewalld.service
		echo $test_password | sudo systemctl disable firewalld.service 
		echo $test_password | sudo iptables -nL
		echo $test_password | sudo sed -i -e 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config
		# reboot required. TODO.
		DebugMsg "Completed RHEL Firewall and SELinux disable"
	fi

	DebugMsg "Proceeding to MPI installation"

	# install MPI packages
	if [ $mpi_name == "ibm" ]; then
		#IBM platform MPI installation
		wget https://partnerpipelineshare.blob.core.windows.net/mpi/platform_mpi-09.01.04.03r-ce.bin
		chmod +x platform_mpi-09.01.04.03r-ce.bin
		echo $test_password | sudo -S /home/$test_user/platform_mpi-09.01.04.03r-ce.bin
		# Enter, 1, Enter, Enter, Enter, Enter
		DebugMsg "Completed IBM Platform MPI installation"

		target_bin=/opt/ibm/platform_mpi/bin/mpirun
		ping_pong_help=/opt/ibm/platform_mpi/help
		ping_pong_bin=/opt/ibm/platform_mpi/help/ping_pong

		# file validation
		if [ -z $target_bin ]; then
			echo "File not found $target_bin"
		else
			echo "File $target_bin found"
		fi

		# compile ping_pong
		cd $ping_pong_help
		echo $test_password | sudo -S make

		# verify ping_pong binary
		if [ -z $ping_pong_bin ]; then
			echo "File not found $ping_pong_bin"
		else
			echo "File $ping_pong_bin found"
		fi

		# add IBM Platform MPI path to PATH
		PATH=$PATH:/opt/ibm/platform_mpi/bin

	elif [ $mpi_name -eq "intel"]; then
		# Intel MPI installation
		echo "Not implemented yet"
	else 
		# Open MPI installation
		echo "Not implemented yet"
	fi
	
	cd ~
	
	DebugMsg "Proceeding Intel MPI Benchmark test installation"

	# install Intel MPI benchmark package
	git clone https://github.com/intel/mpi-benchmarks
	cd mpi-benchmark/src_c
	make
	DebugMsg "Intel Benchmark test installation completed"

	# set string to verify Intel Benchmark binary
	benchmark_bin=/home/lisa/mpi-benchmarks/src_c/IMB-MPI1

	# verify benchmark binary
	if [ -z $benchmark_bin ]; then
		echo "File not found $benchmark_bin"
	else
		echo "File $benchmark_bin found"
	fi

	DebugMsg "Main function completed"
}

# main body

Main