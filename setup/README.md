# Automotive Security Lab Setup
## 2017-02-09 Steel City Information Security Lab
A VM was temporarily provided for the 2017-02-09 lab with the below credentials.
#### VM Login Credentials
* Username:  scis
* Password:  P@ssword

## Configuring a new VM for distribution
If you'd like to replicate the VM that I distributed with the lab, you can follow the below steps.
* Install CentOS 6.8 in a VM[1], login as root, then open a terminal.
  * If you chose the easy install method, VMware Tools should have been installed for you by default.
  * `echo "zNEkKN9rcpM0Q3ARipJ5JMe7Wpl6PLT5RlEaqAAqIuAGyn8AdX2Qns3RYHYiAdYQrCq2K7HLSAinVcigfFN8lFAOM0VTDys5Ju4n" >> /etc/scis.conf`
  * `useradd -m -p $(openssl passwd -1 P@ssword) -s /bin/bash -c "SCIS User" -G wheel scis`
    * If the scis user creation was already done for you, you may want to `usermod -G wheel,scis scis` and use `visudo` to uncomment the wheel permissions.
  * `history -c && gnome-session-save --kill`
* Login as scis
  * Open a terminal
    * `cd ${HOME}/Desktop`
    * `sudo yum -y install git`
    * `git clone git://github.com/JonZeolla/lab-securitydataanalysis.git`
    * `lab-securitydataanalysis/setup/setup.sh -bvf quick`
      * If you get an error about virtualization you need to turn on nested virtualization.  In VMware Fusion 8 you'll need to shut the system down, go under CPUs, then expand the advanced section to turn this on.  After you start it back re-run `setup.sh -bvf quick`
    * # Wait a ~long time
    * `rm ~/.bash_history;history -c`
  * Shutdown the virtual machine using the GUI
* Create the OVA
  * On a Mac using VMware Fusion, this looks something like:

   ```
   cd /Applications/VMware\ Fusion.app/Contents/Library/VMware\ OVF\ Tool/
   ./ovftool --acceptAllEulas /path/to/VM.vmx /path/to/VM.ova
   ```

[1]:  I typically make sure to create VMs as harware version 10 under Compatibility because I've found it fixes some issues with transferring VMs between VMware Fusion and ESXi 5.5.

