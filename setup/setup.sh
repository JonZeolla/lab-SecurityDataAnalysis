#!/usr/bin/env bash
# To enable and disable tracing use:  set -x (On) set +x (Off)
# To terminate the script immediately after any non-zero exit status use:  set -e

# =========================
# Author:          Jon Zeolla (JZeolla, JonZeolla)
# Last update:     2017-02-08
# File Type:       Bash Script
# Version:         1.0-ALPHA
# Repository:      https://github.com/jonzeolla/lab-securitydataanalysis
# Description:     This is a helper script to configure an Apache Metron (incubating) dev environment.
#
# Notes
# - Anything that has a placeholder value is tagged with TODO.
# - In order to pull this down you need to manually install git.
# - If you experience an issue with wget or curl over TLS, update /etc/pki/tls/certs/ca-bundle.crt with the contents from https://curl.haxx.se/ca/cacert.pem.
#
# =========================


## Global Instantiations
# Static Variables
declare -r scriptbegin=$(date +%s)
declare -r usrCurrent="${SUDO_USER:-${USER}}"
declare -r unusedUID="$(awk -F: '{uid[$3]=1}END{for(x=1000;x<=1100;x++) {if(uid[x] != ""){}else{print x; exit;}}}' /etc/passwd)"
declare -r metronRepo="git://github.com/apache/incubator-metron.git"
declare -r OPTSPEC=':dfhm:p:stu:v-:'
# Potential TOCTOU issue with startTime
declare -r startTime="$(date +%Y-%m-%d_%H-%M)"
declare -r txtDEFAULT='\033[0m'
declare -r txtVERBOSE='\033[33;34m'
declare -r txtINFO='\033[0;30m'
declare -r txtWARN='\033[0;33m'
declare -r txtERROR='\033[0;31m'
declare -r txtABORT='\033[1;31m'
# Array Variables
declare -a downloaded
declare -a issues
declare -a branches
declare -A component
declare -A OS
declare -A versions
declare -A prereq
# Integer Variables
declare -i exitCode=0
declare -i verbose=0
declare -i usetheforce=0
declare -i startitup=0
declare -i showthehelp=0
declare -i debugging=0
declare -i mergebranch=0
declare -i mergepr=0
declare -i modifiedvagrant=0
declare -i testmode=0
declare -i addedscpifssh=0
declare -i addedbrackets=0
declare -i buildthedocs=0
# String Variables
declare -- deployChoice=""
declare -- action=""
declare -- usrSpecified=""
declare -- branchSpecified=""
declare -- prSpecified=""


## Populate associative arrays
component[ansible]="2.0.0.2"
component[vagrant]="1.8.1"
# The build version must be specified for the virtualbox download to work properly
component[virtualbox]="5.0.28_111378"
component[python]="2.7.11"
component[maven]="3.3.9"
component[ez_setup]="bootstrap"
component[metron]="master"
versions[supported]="0.3.0","0.3.1"
versions[workaround]="0.3.0","0.3.1"

## Populate additional, more dynamic variables
if command -v python > /dev/null 2>&1 && [[ "Python ${component[python]}" == "$(python --version 2>&1)" ]]; then prereqs[python]="Expected"; else prereqs[python]="Unknown"; fi
if command -v easy_install-${component[python]:0:3} > /dev/null 2>&1 ; then prereqs[ez_setup]="Expected"; else prereqs[ez_setup]="Unknown"; fi
if command -v ansible > /dev/null 2>&1 && [[ "ansible ${component[ansible]}" == "$(ansible --version | head -1)" ]]; then prereqs[ansible]="Expected"; else prereqs[ansible]="Unknown"; fi
if command -v mvn > /dev/null 2>&1 && [[ "Apache Maven ${component[maven]}" == "$(mvn --version | head -1 | awk '{print $1,$2,$3}')" ]]; then prereqs[maven]="Expected"; else prereqs[maven]="Unknown"; fi
if command -v virtualbox > /dev/null 2>&1 && [[ "${component[virtualbox]%%_*}" == "$(vboxmanage --version | cut -f1 -d'r')" ]]; then prereqs[virtualbox]="Expected"; else prereqs[virtualbox]="Unknown"; fi
if command -v vagrant > /dev/null 2>&1 && [[ "Vagrant ${component[vagrant]}" == $(vagrant --version) ]]; then prereqs[vagrant]="Expected"; else prereqs[vagrant]="Unknown"; fi


## Functions
function _getDir() {
    if [ ${component[${1}]}+testingexistence ]; then
        if [[ "${component[${1}]}" != "latest" && "${component[${1}]}" != "master" ]]; then
            echo "/usr/local/${1}/${component[${1}]}"
        else
            echo "/usr/local/${1}/${startTime}"
        fi
    else
        _feedback ABORT "Failed to find the ${1} key in the component array - unable to provide the correct directory for a non-existant key"
    fi
}

function _cleanup() {
    ## Cleanup temporary files, remove empty directories, fix ownership, etc.
    # Make sure the user was created, if not then there is no cleanup to attempt
    if getent passwd ${usrSpecified} > /dev/null; then
        for downloadedFile in "${downloaded[@]}"; do
            if [[ -n "${downloadedFile}" ]]; then
                if [[ "${verbose}" == "1" ]]; then _feedback VERBOSE "Removing ${downloadedFile}"; fi
                # the -r is required in case this is a folder, such as when "${downloadedFile}" is a git repo
                rm -rf "${downloadedFile}"
            fi
        done

        for k in "${!component[@]}"; do
            if [[ -d "$(_getDir "${k}")" ]]; then
                if [[ "${verbose}" == "1" ]]; then _feedback VERBOSE "Recursively chowning $(_getDir ${k}) to have a owner and group of ${usrSpecified}"; fi
                sudo chown -R "${usrSpecified}:" "$(_getDir ${k})"
            elif [[ -d "$(_getDir "${k}")" ]]; then
                if [[ "${verbose}" == "1" ]]; then _feedback VERBOSE "Deleting empty directories related to ${k}"; fi
                rmdir "$(_getDir "${k}")" "$(_getDir "${k}")/.."
            fi
        done
    else
        if [[ "${verbose}" == "1" ]]; then _feedback VERBOSE "${usrSpecified} was never created, skipping cleanup"; fi
    fi
    
    if [[ "${verbose}" == "1" ]]; then
        for issue in "${issues[@]}"; do
            _feedback VERBOSE "Issue encountered - ${issue}"
        done
    fi
}

function _quit() {
        exitCode="${1:-0}"
        _cleanup
        scriptend=$(date +%s)
        if [[ "${verbose}" == "1" ]]; then
            _feedback VERBOSE "$(hostname):$(readlink -f ${0}) $* completed at [`date`] after $(python -c "print '%um:%02us' % ((${scriptend} - ${scriptbegin})/60, (${scriptend} - ${scriptbegin})%60)") with an exit code of ${exitCode}"
        fi
        if [[ "${exitCode}" == "0" ]]; then
            _feedback INFO "Successfully installed and set up Apache Metron (incubating)!  Now how do I use this thing...?"
        fi
        exit "${exitCode}"
}

function _feedback() {
    color="txt${1:-DEFAULT}"
    if [[ "${1}" == "ABORT" ]]; then
        # TODO: Test stderr
        >&2 echo -e "${!color}ERROR:\t\t${2}, aborting...${txtDEFAULT}"
        _quit 1
    elif [[ "${1}" == "ERROR" ]]; then
        exitCode=1
        issues+=("${2}")
        >&2 echo -e "${!color}${1}:\t\t${2}${txtDEFAULT}"
    elif [[ "${1}" == "WARN" ]]; then
        issues+=("${2}")
        >&2 echo -e "${!color}${1}:\t\t${2}${txtDEFAULT}"
    else
        echo -e "${!color}${1}:\t${2}${txtDEFAULT}"
    fi
}

function _downloadit() {
    currComponent="$(basename $(dirname ${PWD}))"
    theFile="${1##*/}"

    # Make sure you're in one of the right dirs
    if [[ "$(_getDir ${currComponent})" == "${PWD}" && ( "${2}" == "wget" || -z "${2}" ) ]]; then
        # Download the file and check for any issues
        wget -q --retry-connrefused -N "${1}"
        if [[ "$?" != 0 ]]; then
            _feedback ERROR "Issue retrieving ${1}"
        else
            downloaded+=("$(_getDir ${currComponent})"/"${theFile}")
        fi
    elif [[ "$(_getDir ${currComponent})" == "${PWD}" && "${2}" == "git" ]]; then
        # Clone the repo and check for any issues
        git clone --recursive "${1}" "$(_getDir ${currComponent})/"
        if [[ "$?" != 0 ]]; then
            _feedback ERROR "Issue git cloning ${1}"
        fi
    else
        _feedback ABORT "Either downloading ${theFile} in the wrong place - currently in ${PWD} - or the second argument sent to _downloadit was unknown - ${2} was provided"
    fi
}

function _managePackages() {
    # Consider using https://github.com/icy/pacapt at some point?
    case "${1}" in
        install)
            action="install" ;;
        update)
            action="update" ;;
        *)
            _feedback ABORT "Issue identifying package management action to take" ;;
    esac

    shift

    if [[ "${action}" == "update" && "${OS[packagemanager]}" == "yum" && "${OS[supported]}" == "true" ]]; then
        sudo yum -y -q "${action}"
    elif [[ "${OS[packagemanager]}" == "yum" && "${OS[supported]}" == "true" ]]; then
        for pkg in "${@}"; do
            # This handles yum installs of local RPMs, remote RPMs, and packages
            rpmQA=$(awk -F\/ '{print $NF}' <<< "${pkg}")
            rpm -qa | grep -qw "${rpmQA%.*}" || sudo yum -y -q "${action}" "${pkg}" || _feedback ERROR "Issue performing \`sudo yum -y -q ${action} ${pkg}\` successfully"
        done
    elif [[ "${OS[packagemanager]}" == "brew" && "${OS[supported]}" == "true" ]]; then
        _feedback ABORT "Homebrew is not yet supported"
    elif [[ "${OS[packagemanager]}" == "Unknown" && "${OS[supported]}" == "true" ]]; then
        _feedback ABORT "Unknown package manager"
    else
        _feedback ABORT "Unknown error validating OS package manager"
    fi
}

function _showHelp() {
    # If there's input, provide it to the user as an error.
    if [[ $# -eq 1 ]]; then
        _feedback ERROR "${1}"
    fi

    # Note that the here-doc is purposefully using tabs, not spaces, for indentation
    cat <<- HEREDOC
	Preferred Usage: ${0##*/} [-bdfhs] [-m BRANCH1,BRANCH2,BRANCH3... | -p PR#] [-u USER] [--] [DEPLOYMENT CHOICE]

	-b|--build			Build the related Metron documentation.
	-d|--debug			Enable debugging.
	-f|--force			Do not prompt before proceeding.
	-h|--help			Print this help.
	-m|--merge			Merge a specified branch or set of branches into metron before building.  Currently mutually exclusive with -p|--pr.
	-p|--pr				Merge a specified pr into metron before building.  Currently mutually exclusive with -m|--merge.
	-s|--start			Start Metron by default.
	-u|--user			Specify the user.
	-v|--verbose			Add verbosity.
	DEPLOYMENT CHOICE		Choose one of QUICK or FULL.

	AUTHOR
	    Written by Jon Zeolla.

	BUGS
	    The long options have not been thoroughly tested, and are probably rife with bugs, hence the preferred usage suggests only short options.
	    The -t flag is not listed above, as it is only meant to be used by the author.
	HEREDOC

    _quit "${exitCode}"
}


## Handle signals
# trap common kill signals
# TODO: Test this
trap '_feedback ABORT "Received a kill signal on $(hostname) while running $(readlink -f ${0}) $* at $(date +%Y-%m-%d_%H:%M)"' SIGINT SIGTERM SIGHUP


## Initial checks
# Setup options
# TODO: Add some better error cases below
while getopts "${OPTSPEC}" optchar; do
    case ${optchar} in
        -)
            # TODO: This needs testing
            # Note that getopts does not perform OPTERR checking nor option-argument parsing for this section
            # For details, see http://stackoverflow.com/questions/402377/using-getopts-in-bash-shell-script-to-get-long-and-short-command-line-options/7680682#7680682
            case "${OPTARG}" in
                build)
                    buildthedocs=1 ;;
                debug)
                    debugging=1 ;;
                force)
                    usetheforce=1 ;;
                help)
                    showthehelp=1 ;;
                merge)
                    mergebranch=1
                    # TODO: Testing
                    # TODO: Need to update this to handle csv
                    # branchSpecified="${!OPTIND}" ;;
                    echo Try1: branchSpecified="${!OPTIND}"
                    input="${!OPTIND}"; OPTIND=$(( $OPTIND + 1 ))
                    echo branchSpecified="${input}"
                    echo "Parsing option: '--${OPTARG}', value: '${input}'"
                    ;;
                merge=*)
                    mergebranch=1
                    # TODO: Testing
                    # TODO: Need to update this to handle csv
                    echo Try1: branchSpecified="${OPTARG#*=}"
                    input=${OPTARG#*=}
                    branchSpecified=${OPTARG%=$input}
                    echo "Parsing option: '--${branchSpecified}', value: '${input}'"
                    ;;
                pr)
                    mergepr=1
                    # TODO: Testing
                    # TODO: Need to update this to handle csv
                    # prSpecified="${!OPTIND}" ;;
                    echo Try1: prSpecified="${!OPTIND}"
                    input="${!OPTIND}"; OPTIND=$(( $OPTIND + 1 ))
                    echo prSpecified="${input}"
                    echo "Parsing option: '--${OPTARG}', value: '${input}'"
                    ;;
                pr=*)
                    mergepr=1
                    # TODO: Testing
                    # TODO: Need to update this to handle csv
                    echo Try1: prSpecified="${OPTARG#*=}"
                    input=${OPTARG#*=}
                    prSpecified=${OPTARG%=$input}
                    echo "Parsing option: '--${prSpecified}', value: '${input}'"
                    ;;
                start)
                    startitup=1 ;;
                user)
                    # TODO: Testing
                    # usrSpecified="${!OPTIND}" ;;
                    echo Try1: usrSpecified="${!OPTIND}"
                    input="${!OPTIND}"; OPTIND=$(( $OPTIND + 1 ))
                    echo usrSpecified="${input}"
                    echo "Parsing option: '--${OPTARG}', value: '${input}'"
                    ;;
                user=*)
                    # TODO: Testing
                    echo Try1: usrSpecified="${OPTARG#*=}"
                    input=${OPTARG#*=}
                    opt=${OPTARG%=$input}
                    echo "Parsing option: '--${opt}', value: '${input}'"
                    ;;
                verbose)
                    verbose=1 ;;
                *)
                    if [ "${OPTERR}" = 1 ] && [ "${OPTSPEC:0:1}" != ":" ]; then
                        _feedback ERROR "Unknown option --${OPTARG}"
                        showthehelp=1
                    fi
                    ;;
            esac ;;
        b)
            buildthedocs=1 ;;
        d)
            debugging=1 ;;
        f)
            usetheforce=1 ;;
        h)
            showthehelp=1 ;;
        m)
            mergebranch=1
            for branch in "${OPTARG//,/ }"; do
                branches+=("${branch}")
            done
            ;;
        p)
            mergepr=1
            prSpecified="${OPTARG}"
            ;;
        s)
            startitup=1 ;;
        t)
            testmode=1 ;;
        u)
            usrSpecified="${OPTARG}" ;;
        v)
            verbose=1 ;;
        '?')
            _feedback ERROR "Invalid option: -${OPTARG}"
            showthehelp=1
            ;;
    esac
done

shift "$((OPTIND-1))"

if [[ ( "${showthehelp}" == "1" ) || ( "${mergebranch}" == "1" && "${mergepr}" == "1" ) ]]; then
    _showHelp
fi

if ! sudo -v > /dev/null 2>&1; then
    _feedback ABORT "No sudo access detected for this user"
fi

# Check remaining argument
case "${1}" in
    [fF][uU][lL][lL]|[fF][uU][lL][lL]-[dD][eE][vV]|[fF][uU][lL][lL]-[dD][eE][vV]-[pP][lL][aA][tT][fF][oO][rR][mM])
        deployChoice="full-dev-platform" ;;
    [qQ][uU][iI][cC][kK]|[qQ][uU][iI][cC][kK]-[dD][eE][vV]|[qQ][uU][iI][cC][kK]-[dD][eE][vV]-[pP][lL][aA][tT][fF][oO][rR][mM])
        deployChoice="quick-dev-platform" ;;
    [cC][oO][dD][eE][lL][aA][bB]|[cC][oO][dD][eE][lL][aA][bB]-[pP][lL][aA][tT][fF][oO][rR][mM])
        deployChoice="codelab-platform" ;;
    [fF][aA][sS][tT][cC][aA][pP][aA]|[fF][aA][sS][tT][cC][aA][pP][aA]-[tT][eE][sS][tT]|[fF][aA][sS][tT][cC][aA][pP][aA]-[tT][eE][sS][tT]-[pP][lL][aA][tT][fF][oO][rR][mM])
        deployChoice="fastcapa-test-platform" ;;
    *)
        if [[ "${startitup}" == "1" ]]; then
            _showHelp "You requested to start metron by default but did not specify a valid deployment choice"
        fi
        ;;
esac


# Validate the OS
# TODO: Test this more comprehensively
# Beware of assumptions otherwise in the code that this is running on linux, such as the naming of variables in _downloadit
case "${OSTYPE}" in
    darwin*)
        OS[distro]="Mac"
        OS[version]="${OSTYPE:6}"
        # TODO: Purposefully still not supported by default, but maybe soon
        if [[ "${OS[version]}" == "16" ]]; then
            OS[supported]="false"
        else
            OS[supported]="false"
        fi
        ;;
    linux*)
        if [[ -r /etc/centos-release ]]; then
            OS[distro]="$(awk -F\  '{print $1}' /etc/centos-release)"
            OS[version]="$(awk -F\  '{print $(NF-1)}' /etc/centos-release)"
            if [[ "${OS[distro]}" == "CentOS" && ("${OS[version]}" == "6.8") ]]; then
                OS[supported]="true"
            else
                OS[supported]="false"
            fi
        else
            OS[distro]="Linux"
            OS[version]="Unknown"
            OS[supported]="false"
        fi
        ;;
    bsd*)
        OS[distro]="BSD"
        OS[version]="Unknown"
        OS[supported]="false" ;;
    msys*)
        OS[distro]="Windows"
        OS[version]="Unknown"
        OS[supported]="false" ;;
    solaris*)
        OS[distro]="Solaris"
        OS[version]="Unknown"
        OS[supported]="false" ;;
    *)
        OS[distro]="Unknown"
        OS[version]="Unknown"
        OS[supported]="false" ;;
esac

if [[ "${OS[supported]}" == "true" ]]; then
    # TODO: Handle this better
    if command -v yum > /dev/null 2>&1 ; then
        OS[packagemanager]="yum"
    else
        OS[packagemanager]="Unknown"
    fi
    if [[ "${verbose}" == "1" ]]; then _feedback VERBOSE "Your OS is supported (Distro: ${OS[distro]}, Version ${OS[version]})"; fi
elif [[ "${OS[supported]}" == "false" ]]; then
    _feedback ABORT "Your OS is not supported (Distro: ${OS[distro]}, Version ${OS[version]})"
else
    _feedback ABORT "Unknown error checking OS support"
fi


# Ensure basic tool(s)
if [[ "${verbose}" == "1" ]]; then _feedback VERBOSE "Installing some basic tools"; fi
if [[ "${OS[distro]}" == "CentOS" && "${OS[supported]}" == "true" ]]; then
    if ! command -v wget > /dev/null 2>&1 ; then
        _managePackages "install" "wget"
    fi
    _managePackages "install" "yum-utils"
fi

# Check network connectivity
if [[ "${verbose}" == "1" ]]; then _feedback VERBOSE "Checking network connectivity"; fi
wget -q --spider 'www.github.com' || _feedback ABORT "Unable to contact github.com"

# Check for virtualization extensions
if [[ "${verbose}" == "1" ]]; then _feedback VERBOSE "Ensuring that virtualization extensions are available"; fi
if ! egrep '(vmx|svm)' /proc/cpuinfo > /dev/null 2>&1 ; then
    _feedback ABORT "Your system does not support virtualization, which is required for this system to run Metron using vagrant and virtualbox"
fi

# Ask the user for confirmation
if [[ "${verbose}" == "1" ]]; then
    for k in "${!component[@]}"; do
        if [[ "${k}" != "metron" && "${prereqs[${k}]}" == "Expected" ]]; then
            _feedback VERBOSE "${k} is the expected version, no changes to be made"
        elif [[ "${k}" == "metron" || "${prereqs[${k}]}" == "Unknown" ]]; then
            if [[ "${component[${k}]}" != "latest" && "${component[${k}]}" != "master" ]]; then
                _feedback VERBOSE "Planning to use ${k} ${component[${k}]}"
            else
                _feedback VERBOSE "Planning to use the latest version of ${k} as of ${startTime}"
            fi
        else
            _feedback ABORT "Unknown error preparing feedback language"
        fi
    done
fi

# TODO: This needs tested
if [[ "${usetheforce}" != "1" ]]; then
    if [[ "${verbose}" == "1" ]]; then _feedback VERBOSE "Asking the user for confirmation"; fi
    while [ -z "${prompt}" ]; do
        read -p "This script is intended to be run on a fresh CentOS 6.8 installation and may have unintended side effects otherwise.  Do you want to continue (y/N)? " prompt
        case "${prompt}" in
            [yY]|[yY][eE][sS])
                _feedback INFO "Please note that this script may take a long time (60+ minutes) to complete"
                sleep 1s
                _feedback INFO "Continuing..." ;;
            ""|[nN]|[nN][oO])
                _feedback ABORT "Did not want to continue" ;;
            *)
                _feedback ABORT "Unknown response" ;;
        esac
    done
fi

# Make sure that this is being installed on a system with the GUI installed and running
if [[ -z "${DESKTOP_SESSION}" ]]; then
    _feedback ABORT "This script must be run on a system with the GUI installed and running"
fi


## Check access which will be required later (filesystem ACLs, etc.)
# TODO


## Beginning of main script
# Default the user to the current user if it wasn't set
usrSpecified="${usrSpecified:-$USER}"

# Install pre-reqs
if [[ "${OS[distro]}" == "CentOS" ]]; then
    if [[ "${verbose}" == "1" ]]; then _feedback VERBOSE "Installing some CentOS pre-reqs"; fi
    # Be aware that the following commands may give a "repomd.xml does not match metalink for epel." error every once in a while due to epel resynchronization.
    _managePackages "install" "epel-release"
    _managePackages "update"
    _managePackages "install" "gdm" "zlib-devel" "bzip2-devel" "openssl-devel" "ncurses-devel" "sqlite-devel" "readline-devel" "tk-devel" "gdbm-devel" "db4-devel" "libpcap-devel" "xz-devel" "dkms"
fi

# Set up a user
if [[ "${usrSpecified}" != "${USER}" ]]; then
    if [[ "${verbose}" == "1" ]]; then _feedback VERBOSE "Creating a new user and group of ${usrSpecified}"; fi
    sudo groupadd -g "${unusedUID}" "${usrSpecified}" || _feedback ERROR "Unable to create group ${usrSpecified} with GID ${unusedUID}"
    sudo useradd -d "/home/${usrSpecified}" -g "${usrSpecified}" -G wheel -s /bin/bash -u "${unusedUID}" "${usrSpecified}" || _feedback ERROR "Unable to create user ${usrSpecified} with UID ${unusedUID}"
    sudo passwd "${usrSpecified}" || _feedback ERROR "Unable to reset the password for ${usrSpecified}"
    if [[ "${verbose}" == "1" ]]; then _feedback VERBOSE "Giving ${usrSpecified} full sudo access"; fi
    sudo sed -i "98s/^# //" /etc/sudoers || _feedback ERROR "Unable to modify /etc/sudoers"
fi

# Setup some directories
for k in "${!component[@]}"; do
    if [[ "${verbose}" == "1" ]]; then _feedback VERBOSE "Setting up an install directory for ${k}"; fi
    sudo mkdir -p "$(_getDir ${k})" || _feedback ERROR "Unable to mkdir $(_getDir ${k})"
    sudo chown "${usrSpecified}:" "$(_getDir ${k})" || _feedback ERROR "Unable to chown ${usrSpecified}: $(_getDir ${k})"
done

# Setup python
if [[ "${prereqs[python]}" == "Expected" ]]; then
    _feedback INFO "Python ${component[python]} already appears to be active, skipping..."
else
    if [[ "${verbose}" == "1" ]]; then _feedback VERBOSE "Installing python into $(_getDir "python")"; fi
    cd "$(_getDir "python")"
    _downloadit "https://www.python.org/ftp/python/${component[python]}/Python-${component[python]}.tgz"
    tar -xvf "Python-${component[python]}.tgz" --strip 1 || _feedback ERROR "Unable to untar $(_getDir "python")/Python-${component[python]}.tgz"
    ./configure --prefix=/usr/local --enable-unicode=ucs4 --enable-shared LDFLAGS="-Wl,-rpath /usr/local/lib" || _feedback ERROR "Unable to configure python"
    make && sudo make altinstall || _feedback ERROR "Unable to \`sudo make altinstall\` python"
    sudo ln -fs "/usr/local/bin/python${component[python]:0:3}" /usr/local/bin/python || _feedback ERROR "Unable to link python${component[python]:0:3} to /usr/local/bin/python"
fi

# Setup ez_setup
if [[ "${prereqs[ez_setup]}" == "Expected" ]]; then
    _feedback INFO "ez_python ${component[ez_setup]} ($(easy_install-${component[python]:0:3} --version | awk '{print $2}')) already appears to be active, skipping..."
else
    if [[ "${verbose}" == "1" ]]; then _feedback VERBOSE "Installing ez_setup into $(_getDir "ez_setup")"; fi
    cd "$(_getDir "ez_setup")"
    _downloadit "https://bootstrap.pypa.io/ez_setup.py"
    sudo /usr/local/bin/python ez_setup.py || _feedback ERROR "Unable to setup ez_python.py"
    sudo "/usr/local/bin/easy_install-${component[python]:0:3}" pip || _feedback ERROR "Unable to setup pip"
    sudo /usr/local/bin/pip -q install virtualenv paramiko PyYAML Jinja2 httplib2 six setuptools || _feedback ERROR "Unable to install tools with pip"
fi


# Setup ansible
if [[ "${prereqs[ansible]}" == "Expected" ]]; then
    _feedback INFO "Ansible ${component[ansible]} already appears to be active, skipping..."
else
    if [[ "${verbose}" == "1" ]]; then _feedback VERBOSE "Installing ansible using pip"; fi
    sudo /usr/local/bin/pip -q install "ansible==${component[ansible]}" || _feedback ERROR "Unable to install ansible"
fi

# Setup maven
if [[ "${prereqs[maven]}" == "Expected" ]]; then
    _feedback INFO "Maven ${component[maven]} already appears to be active, skipping..."
else
    if [[ "${verbose}" == "1" ]]; then _feedback VERBOSE "Installing maven into $(_getDir "maven")"; fi
    cd "$(_getDir "maven")"
    _managePackages "install" "java-1.8.0-openjdk-devel"
    _downloadit "http://mirrors.ibiblio.org/apache/maven/maven-${component[maven]:0:1}/${component[maven]}/binaries/apache-maven-${component[maven]}-bin.tar.gz"
    tar -xvf "apache-maven-${component[maven]}-bin.tar.gz" --strip 1 || _feedback ERROR "Unable to untar $(_getDir "maven")/apache-maven-${component[maven]}-bin.tar.gz"
    echo "export M2_HOME=$(_getDir "maven")" | sudo tee /etc/profile.d/maven.sh > /dev/null || _feedback ERROR "Unable to overwrite /etc/profile.d/maven.sh"
    echo "export PATH=${M2_HOME}/bin:${PATH}" | sudo tee -a /etc/profile.d/maven.sh > /dev/null || _feedback ERROR "Unable to append to /etc/profile.d/maven.sh"
    sudo chmod o+x /etc/profile.d/maven.sh || _feedback ERROR "Unable to chmod o+x /etc/profile.d/maven.sh"
    /etc/profile.d/maven.sh || _feedback ERROR "Unable to run /etc/profile.d/maven.sh"
    sudo ln -fs "/usr/local/maven/${component[maven]}/bin/mvn" /usr/local/bin/mvn || _feedback ERROR "Unable to link /usr/local/maven/${component[maven]}/bin/mvn to /usr/local/bin/mvn"
fi

# Setup virtualbox
if [[ "${prereqs[virtualbox]}" == "Expected" ]]; then
    _feedback INFO "Virtualbox ${component[virtualbox]%%_*} already appears to be active, skipping..."
else
    if [[ "${verbose}" == "1" ]]; then _feedback VERBOSE "Installing virtualbox into $(_getDir "virtualbox")"; fi
    cd "$(_getDir "virtualbox")"
    _downloadit "http://download.virtualbox.org/virtualbox/${component[virtualbox]%%_*}/VirtualBox-${component[virtualbox]:0:3}-${component[virtualbox]}_el6-1.x86_64.rpm"
    _managePackages "install" "VirtualBox-${component[virtualbox]:0:3}-${component[virtualbox]}_el6-1.x86_64.rpm"
    sudo usermod -a -G vboxusers "${usrSpecified}" || _feedback ERROR "Unable to add ${usrSpecified} to the vboxusers group"
    if [[ "${usrCurrent}" == "${usrSpecified}" && $(getent group vboxusers | grep "${usrSpecified}") && ! $(id -Gn | grep vboxusers) ]]; then
        _feedback WARN "In order to take advantage of new group memberships you should log out and log in again, but I'll try to account for this later in the script..."
    fi
fi 

# Setup vagrant
if [[ "${prereqs[vagrant]}" == "Expected" ]]; then
    _feedback INFO "Vagrant ${component[vagrant]} already appears to be active, skipping..."
else
    if [[ "${verbose}" == "1" ]]; then _feedback VERBOSE "Installing vagrant into $(_getDir "vagrant")"; fi
    cd "$(_getDir "vagrant")"
    _downloadit "https://releases.hashicorp.com/vagrant/${component[vagrant]}/vagrant_${component[vagrant]}_x86_64.rpm"
    _managePackages "install" "vagrant_${component[vagrant]}_x86_64.rpm"
    vagrant plugin install vagrant-hostmanager || _feedback ERROR "Unable to install the vagrant-hostmanager vagrant plugin"
fi 

# Setup Metron
if [[ "${verbose}" == "1" ]]; then _feedback VERBOSE "Installing metron into $(_getDir "metron")"; fi
# TODO: Allow a way to pull down and setup a specific, older version by checking out the ref
# TODO: Fetching specific refs may cause an issue with the PR merge feature
cd "$(_getDir "metron")"
_downloadit "${metronRepo}" "git"
if [[ "${mergebranch}" == "1" ]]; then
    if [[ "${verbose}" == "1" ]]; then _feedback VERBOSE "Merging the branches ${branches[@]} into $(_getDir "metron")"; fi
    for branch in "${branches[@]}"; do
        git merge "${branch}" || _feedback ABORT "Unable to merge the ${branch} branch"
    done
elif [[ "${mergepr}" == "1" ]]; then
    if [[ "${verbose}" == "1" ]]; then _feedback VERBOSE "Merging the pr ${prSpecified} into $(_getDir "metron")"; fi
    isgit="$(git rev-parse --is-inside-work-tree || echo false)"
    curBranch="$(git branch | grep \* | awk '{print $2}')"
    theOrigin="$(git remote -v | grep -m 1 origin | awk '{print $2}')"
    if [[ "${isgit}" == "true" && "${curBranch}" == "${component[metron]}" && "${theOrigin}" == "${metronRepo}" ]]; then
        git fetch origin "pull/${prSpecified}/head:pr-${prSpecified}" || _feedback ERROR "Issue fetching the ${prSpecified} PR"
        git merge "pr-${prSpecified}" || _feedback ERROR "Issue merging the ${prSpecified} PR"
    else
        _feedback "ABORT" "Something went wrong when trying to merge pr ${prSpecified} into $(_getDir "metron")"
    fi
fi
if [[ "${buildthedocs}" == "1" && $(grep "^metron_version: " "$(_getDir "metron")/metron-deployment/inventory/${deployChoice}/group_vars/all" | awk '{print $NF}') != "0.3.0" ]]; then
    if [[ "${verbose}" == "1" ]]; then _feedback VERBOSE "Building the related Metron docs"; fi
    cd "$(_getDir "metron")/site-book"
    bin/generate-md.sh || _feedback ERROR "Issue running generate-md.sh"
    /usr/local/bin/mvn site:site || _feedback ERROR "Issue building the Metron docs"
elif [[ "${buildthedocs}" == "0" && $(grep "^metron_version: " "$(_getDir "metron")/metron-deployment/inventory/${deployChoice}/group_vars/all" | awk '{print $NF}') == "0.3.0" ]]; then
    _feedback ERROR "Unable to build the docs on Metron 0.3.0 because that function didn't exist yet, please refer to the README.md files individually"
else
    _feedback ABORT "Unknown error during document building logic"
fi
if [[ "${verbose}" == "1" ]]; then _feedback VERBOSE "Building Metron"; fi
/usr/local/bin/mvn clean package -DskipTests || _feedback ABORT "Issue building Metron"
    
if [[ "Python ${component[python]}" == $(python --version 2>&1) && -x $(which easy_install-${component[python]:0:3}) && "ansible ${component[ansible]}" == $(ansible --version | head -1) && "${component[virtualbox]%%_*}" == "$(vboxmanage --version | cut -f1 -d'r')" && "Vagrant ${component[vagrant]}" == $(vagrant --version) ]]; then
    # Start Metron, if appropriate
    if [[ "${startitup}" == "1" ]]; then
        # Required for older versions of Metron
        if ! grep -q "^    ansible\.verbose = \"vvvv\"$" "$(_getDir "metron")/metron-deployment/vagrant/${deployChoice}/Vagrantfile" && [[ "${debugging}" == "1" ]]; then
            sed -i '/ansible.playbook/a     ansible.verbose = "vvvv"' "$(_getDir "metron")/metron-deployment/vagrant/${deployChoice}/Vagrantfile" && modifiedvagrant=1
        fi
        if [[ "${usrCurrent}" == "${usrSpecified}" ]]; then
            if [[ "${verbose}" == "1" ]]; then _feedback VERBOSE "Starting up metron's \"${deployChoice}\""; fi
            cd "$(_getDir "metron")/metron-deployment/vagrant/${deployChoice}"
            # Fixed as of METRON-635, awaiting merge via PR #411
            # TODO: This solution is not super clean for the situation where the PR gets merged but a new release has not come out, but it should still work.  Probably worth a clean up at that point.
            for version in $(echo "${versions[workaround]}" | tr , '\n'); do
                if [[ $(grep "^metron_version: " "$(_getDir "metron")/metron-deployment/inventory/${deployChoice}/group_vars/all" | awk '{print $NF}') == "${version}" && "${testmode}" == "0" ]]; then
                    if ! grep -q "scp_if_ssh = True" "$(_getDir "metron")/metron-deployment/vagrant/${deployChoice}/ansible.cfg"; then
                        if grep -q "\[ssh_connection\]" "$(_getDir "metron")/metron-deployment/vagrant/${deployChoice}/ansible.cfg"; then
                            sed -i '/\[ssh_connection\]/a scp_if_ssh = True' "$(_getDir "metron")/metron-deployment/vagrant/${deployChoice}/ansible.cfg"
                            addedscpifssh=1
                        else
                            echo -e "\n\n[ssh_connection]\nscp_if_ssh = True" >> "$(_getDir "metron")/metron-deployment/vagrant/${deployChoice}/ansible.cfg"
                            if [[ "$?" == 0 ]]; then
                                addedscpifssh=1
                                addedbrackets=1
                            fi
                        fi
                    fi
                fi
            done
            sg vboxusers -c "vagrant up" || _feedback ERROR "Unable to run sg vboxusers -c \"vagrant up\""
            if [[ "${deployChoice}" == "codelab-platform" ]]; then
                ./run.sh || _feedback ERROR "Unable to run ./run.sh"
            fi
        elif sudo -v -u "${usrSpecified}" > /dev/null 2>&1 ; then
            if [[ "${verbose}" == "1" ]]; then _feedback VERBOSE "Starting up metron's \"${deployChoice}\" as \"${usrSpecified}\""; fi
            cd "$(_getDir "metron")/metron-deployment/vagrant/${deployChoice}"
            # Fixed as of METRON-635
            if [[ $(grep "^metron_version: " "$(_getDir "metron")/metron-deployment/inventory/${deployChoice}/group_vars/all" | awk '{print $NF}') =~ "${versions[workaround]}" ]]; then
                if [[ "${testmode}" == "0" ]]; then
                    if ! grep -q "scp_if_ssh = True" "$(_getDir "metron")/metron-deployment/vagrant/${deployChoice}/ansible.cfg"; then
                        if grep -q "\[ssh_connection\]" "$(_getDir "metron")/metron-deployment/vagrant/${deployChoice}/ansible.cfg"; then
                            sed -i '/\[ssh_connection\]/a scp_if_ssh = True' "$(_getDir "metron")/metron-deployment/vagrant/${deployChoice}/ansible.cfg" && addedscpifssh=1
                        else
                            echo -e "\n\n[ssh_connection]\nscp_if_ssh = True" >> "$(_getDir "metron")/metron-deployment/vagrant/${deployChoice}/ansible.cfg"
                            if [[ "$?" == 0 ]]; then
                                addedscpifssh=1
                                addedbrackets=1
                            fi
                        fi
                    fi
                fi
            fi
            sudo -u "${usrSpecified}" vagrant up || _feedback ERROR "Unable to run sudo -u ${usrSpecified} \"vagrant up\""
            if [[ "${deployChoice}" == "codelab-platform" ]]; then
                ./run.sh || _feedback ERROR "Unable to run ./run.sh"
            fi
        else
            if [[ "${modifiedvagrant}" == "1" && "${debugging}" == "1" ]]; then
                # Cleanup
                sed -i '/^    ansible\.verbose = \"vvvv\"$/d' "$(_getDir "metron")/metron-deployment/vagrant/${deployChoice}/Vagrantfile"
            fi
            _feedback ABORT "Unable to run vagrant up as \"${usrSpecified}\""
        fi
        if [[ "${testmode}" == "0" ]]; then
            # Cleanup
            if [[ "${addedscpifssh}" == "1" ]]; then
                sed -i '/scp_if_ssh = True/d' "$(_getDir "metron")/metron-deployment/vagrant/${deployChoice}/ansible.cfg"
            fi
            if [[ "${addedbrackets}" == "1" ]]; then
                sed -i '/\[ssh_connection\]/d' "$(_getDir "metron")/metron-deployment/vagrant/${deployChoice}/ansible.cfg"
            fi
        fi
        if [[ "${modifiedvagrant}" == "1" && "${debugging}" == "1" ]]; then
            # Cleanup
            sed -i '/^    ansible\.verbose = \"vvvv\"$/d' "$(_getDir "metron")/metron-deployment/vagrant/${deployChoice}/Vagrantfile"
        fi
    fi
else
    _feedback ABORT "Detected an issue with dependancy versions"
fi

## Exit appropriately
_quit "${exitCode}"
