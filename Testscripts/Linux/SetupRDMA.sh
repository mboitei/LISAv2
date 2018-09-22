#!/bin/bash
#
# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the Apache License.
# This script will set up RDMA over IB environment.
# To run this script following things are must.
# 1. constants.sh
# 2. All VMs in cluster have infiniband hardware.
# 3. This script should run in each VM in RDMA test-bed. The main function is
# already applied to VERIFY-INFINIBAND-MultiVM.ps1. This can be running
# for developer testing.
# SetupRDMA.sh $mpi_name $distro_code $debug
# 
########################################################################################################
Source utils.sh
. utils.sh || {
	echo "Error: unable to source utils.sh!"
	echo "TestAborted" >state.txt
	exit 0
}

# Source constants file and initialize most common variables
UtilsInit

# Constants/Globals
HOMEDIR="/root"

# CONSTANTS_FILE="/root/constants.sh"
test_user=lisa
test_super_user=root
test_password=Skynet@is@c0ming
# mpi_name determines which version of MPI installed. 3 values; ibm, open, intel
# mpi_name=$1
mpi_name="ibm"

# find other distro name assignment update
# _distro=$2
_distro="RHEL"

# debug msg flag
# debug=$3
debug=1

# functions
function Debug_Msg {
	if [ $debug -eq 1 ]; then
		echo
		echo "******** DEBUG ********" $1
		echo
	fi
}

function Verify_File {
	if [ -z $1 ]; then
		echo "File not found $1"
	else
		echo "File $1 found"
	fi
}

function Verify_Result {
	if [ $? -eq 0 ]; then
		echo OK
	else
		echo FAIL
fi
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
	ssh-keygen -f id_rsa -b 2048 -t rsa -N '' -f ~/.ssh/id_rsa
	Verify_Result
	Debug_Msg "Generated ssh RSA key"

	# read $slaves and assign each to vm_arr array
	IFS=',' read -r -a vm_arr <<< "$slaves"
	Verify_Result
	Debug_Msg "Read the number of VM - $slaves"

	# sshpass installation for master
	echo $test_password | sudo -S yum install -y sshpass
	Verify_Result

	# building trust of passwordless ssh connection among all VMs
	# sending RSA pub key from master to each slave
	for _vm in "${vm_arr[@]}"; do
		# sshpass -p $test_password ssh-copy-id -o StrictHostKeyChecking=no $test_user@$_vm
		sshpass -p $test_password ssh-copy-id -i .ssh/id_rsa.pub -o StrictHostKeyChecking=no $test_user@$_vm
		Verify_Result
		Debug_Msg "Copied ssh pub key to VM $_vm"
	done
	
	# sending RSA pub key from each slave to others
	for _vm_send in "${vm_arr[@]}"; do
		for _vm_receive in "${vm_arr[@]}"; do
			if [ $_vm_send == $_vm_receive ]; then
				Debug_Msg "Skip this copy step because of itself"
			else
				ssh $test_user@$_vm_send "sshpass -p $test_password ssh-copy-id -i .ssh/id_rsa.pub $test_user@$_vm_receive"
				Verify_Result
				Debug_Msg "Send ssh pub key from $_vm_send to $_vm_receive"
			fi
		done
	done

	# install required packages
	if [ $_distro == "RHEL" ]; then
		echo $test_password | sudo -S yum install -y kernel-devel-3.10.0-862.9.1.el7.x86_64 python-devel valgrind-devel
		Verify_Result
		echo $test_password | sudo -S yum install -y redhat-rpm-config rpm-build gcc-gfortran libdb-devel gcc-c++
		Verify_Result
		echo $test_password | sudo -S yum install -y glibc-devel zlib-devel numactl-devel libmnl-devel binutils-devel
		Verify_Result
		echo $test_password | sudo -S yum install -y iptables-devel libstdc++-devel libselinux-devel gcc elfutils-devel
		Verify_Result
		echo $test_password | sudo -S yum install -y libtool libnl3-devel git java libstdc++.i686
		Verify_Result
		Debug_Msg "Completed the required packages installation"
	fi

	# remove or disable firewall and selinux services, if needed
	if [ $_distro == "RHEL" ]; then
		echo $test_password | sudo systemctl stop iptables.service
		echo $test_password | sudo systemctl disable iptables.service
		echo $test_password | sudo systemctl mask firewalld
		echo $test_password | sudo systemctl stop firewalld.service
		Verify_Result
		echo $test_password | sudo systemctl disable firewalld.service 
		Verify_Result
		echo $test_password | sudo iptables -nL
		Verify_Result
		echo $test_password | sudo sed -i -e 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config
		Verify_Result
		# reboot required. TODO.
		Debug_Msg "Completed RHEL Firewall and SELinux disabling"
	fi

	Debug_Msg "Proceeding to MPI installation"

	# install MPI packages
	if [ $mpi_name == "ibm" ]; then
		echo "IBM Platform MPI: running ..."
		#IBM platform MPI installation
		wget https://partnerpipelineshare.blob.core.windows.net/mpi/platform_mpi-09.01.04.03r-ce.bin
		Verify_Result
		Debug_Msg "Downloading IBM Platform MPI bin file"
		chmod +x platform_mpi-09.01.04.03r-ce.bin
		Debug_Msg "Added execution mode"

		# create a temp file for key stroke event handle
		echo '\n' > /home/$test_user/ibm_keystroke
		echo 1 >> /home/$test_user/ibm_keystroke
		echo /opt/ibm/platform_mpi/ >> /home/$test_user/ibm_keystroke
		echo Y >> /home/$test_user/ibm_keystroke
		echo '\n' >> /home/$test_user/ibm_keystroke
		echo '\n' >> /home/$test_user/ibm_keystroke
		echo '\n' >> /home/$test_user/ibm_keystroke
		echo '\n' >> /home/$test_user/ibm_keystroke

		echo $test_password | sudo cat ibm_keystroke | sudo -S /home/$test_user/platform_mpi-09.01.04.03r-ce.bin
		Verify_Result
		Debug_Msg "Completed IBM Platform MPI installation"

		target_bin=/opt/ibm/platform_mpi/bin/mpirun
		ping_pong_help=/opt/ibm/platform_mpi/help
		ping_pong_bin=/opt/ibm/platform_mpi/help/ping_pong

		# file validation
		Verify_File $target_bin

		# compile ping_pong
		cd $ping_pong_help
		echo $test_password | sudo -S make
		Verify_Result

		# verify ping_pong binary
		Verify_File $ping_pong_bin

		# add IBM Platform MPI path to PATH
		PATH=$PATH:/opt/ibm/platform_mpi/bin

	elif [ $mpi_name -eq "intel"]; then
		# Intel MPI installation
		echo "Intel MPI: Not implemented yet"
	else 
		# Open MPI installation
		echo "Open MPI: Not implemented yet"
	fi
	
	cd ~
	
	Debug_Msg "Proceeding Intel MPI Benchmark test installation"

	# install Intel MPI benchmark package
	git clone https://github.com/intel/mpi-benchmarks
	Verify_Result
	Debug_Msg "Cloning Intel MPI Benchmark gitHub repo"
	cd mpi-benchmarks/src_c
	make
	Verify_Result
	Debug_Msg "Intel Benchmark test installation completed"

	# set string to verify Intel Benchmark binary
	benchmark_bin=/home/lisa/mpi-benchmarks/src_c/IMB-MPI1

	# verify benchmark binary
	Verify_File $benchmark_bin

	Debug_Msg "Main function completed"
}

function post_verification() {
	# Validate if the platform MPI binaries work in the system.
	_hostname=$(cat /etc/hostname)
	_ipaddress=$(hostname -I | awk '{print $1}')
	Debug_Msg "Found hostname from system - $_hostname"
	Debug_Msg "Found _ipaddress from system - $_ipaddress"

	# MPI hostname cmd for initial test
	_res_hostname=$(/opt/ibm/platform_mpi/bin/mpirun -TCP -hostlist $_ipaddress:1 hostname)
	Debug_Msg "_res_hostname $_res_hostname"

	if [ $_hostname = $_res_hostname ]; then
		Debug_Msg "Verified hostname from MPI running"
		echo "Found hostname matching from system info"
	fi

	# MPI ping_pong cmd for initial test
	_res_pingpong=$(/opt/ibm/platform_mpi/bin/mpirun -TCP -hostlist $_ipaddress:1,$_ipaddress:1 /opt/ibm/platform_mpi/help/ping_pong 4096)
	Debug_Msg "_res_pingpong $_res_pingpong"

	_res_tx=$(echo $_res_pingpong | cut -d' ' -f7)
	_res_rx=$(echo $_res_pingpong | cut -d' ' -f11)
	Debug_Msg "_res_tx $_res_tx"
	Debug_Msg "_res_rx $_res_rx"

	if [[ "$_res_tx" != "0" && "$_res_rx" != "0" ]]; then
		echo "Found non-zero value in self ping_pong test"
	else
		echo "Found zero ping_pong test result"
	fi
}

# main body
Main
post_verification