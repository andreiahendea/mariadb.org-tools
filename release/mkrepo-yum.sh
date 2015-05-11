#!/bin/bash - 
#===============================================================================
#
#          FILE:  mkrepo-yum.sh
# 
#         USAGE:  ./mkrepo-yum.sh <archive_dir>
# 
#   DESCRIPTION:  A script to generate the yum repositories for our RPM
#                 packages.
#
#                 The script copies files from the archive directory into
#                 separate directories for each distribution/cpu combination
#                 (just like they are stored in the archive directory). For
#                 best results, it should be run within an empty directory.
#
#                 After running the script, the directories are uploaded to the
#                 YUM server, replacing the previous version in that series
#                 (i.e. the 5.5.23 files are replaced by the 5.5.24 files and
#                 the 5.3.6 files are replaced by the 5.3.7 files, and so on).
# 
#===============================================================================

umask 002

# Right off the bat we want to log everything we're doing and exit immediately
# if there's an error
set -ex
  # -e  Exit immediately if a simple command exits with a non-zero status,
  #     unless the command that fails is part of an until or  while loop, part
  #     of an if statement, part of a && or || list, or if the command's return
  #     status is being inverted using !.  -o errexit
  #
  # -x  Print a trace of simple commands and their arguments after they are
  #     expanded and before they are executed.

#-------------------------------------------------------------------------------
#  Set command-line options
#-------------------------------------------------------------------------------
GALERA="$1"                       # copy in galera packages? 'yes' or 'no'
ENTERPRISE="$2"                   # is this an enterprise release? 'yes' or 'no'

ARCHDIR="$3"                      # path to x86 & x86_64 packages
P8_ARCHDIR="$4"                   # path to ppc64 packages (optional)

#-------------------------------------------------------------------------------
#  Variables which are not set dynamically (because they don't change often)
#-------------------------------------------------------------------------------
galera_versions="25.3.9"                          # Version of galera in repos
#galera_dir="/ds413/galera"                        # Location of galera pkgs
#jemalloc_dir="/ds413/vms-customizations/jemalloc" # Location of jemalloc pkgs
#at_dir="/ds413/vms-customizations/advance-toolchain/" # Location of at pkgs
dists="sles11 sles12 opensuse13 centos5 rhel5 centos6 rhel6 centos7 rhel7 fedora19 fedora20 fedora21"
distros="sles opensuse centos rhel fedora"


# The following set the major versions of various Linux distributions for which
# we build packages.
vers_maj_opensuse="13"
vers_maj_rhel="5 6 7"
vers_maj_centos="5 6 7"
vers_maj_fedora="19 20 21"
vers_maj_sles="11 12"

# MariaDB and MariaDB Enterprise differ as to the CPU architectures you can get
# packages for, and which gpg key is used to sign packages.
if [ "${ENTERPRISE}" = "yes" ]; then
  dists="sles11 sles12 opensuse13 centos5 rhel5 centos6 rhel6 centos7 rhel7" #remove fedora19, fedora20 (refer ME-234)
  distros="sles opensuse centos rhel"    #remove fedora19, fedora20(refer ME-234)
  p8_dists="rhel6 rhel7 rhel71 sles12"
  p8_architectures="ppc64 ppc64le"
  #gpg_key="0xd324876ebe6a595f"               # original enterprise key
  gpg_key="0xce1a3dd5e3c94f49"                # new enterprise key (2014-12-18)
  suffix="signed-ent"
  architectures="amd64"
  archs_std="amd64:x86_64"
  archs_rhel_6="amd64:x86_64 ppc64:ppc64"
  archs_rhel_7="amd64:x86_64 ppc64:ppc64 ppc64le:ppc64le"
  archs_sles_12="amd64:x86_64 ppc64le:ppc64le"
else
  gpg_key="0xcbcb082a1bb943db"                 # mariadb.org signing key
  suffix="signed"
  architectures="amd64 x86"
  archs_std="x86:i386 amd64:x86_64"
  archs_rhel_6=${archs_std}
  archs_rhel_7="amd64:x86_64"
  archs_sles_12="amd64:x86_64"
fi

# The following Linux distributions have the same architectures for both
# MariaDB and MariaDB Enterprise
archs_rhel_5=${archs_std}
archs_centos_5=${archs_std}
archs_centos_6=${archs_std}
archs_centos_7="amd64:x86_64"
archs_fedora_19=${archs_std}
archs_fedora_20=${archs_std}
archs_fedora_21=${archs_std}
archs_sles_11=${archs_std}
archs_opensuse_13=${archs_std}

# CentOS and Redhat have minor versions that need to be accounted for in the
# dir structure. The values here are the first and last value, respectively.
# They are expanded to all the other values using the seq utility. For example,
# a value of '0 4' will be expanded to '0 1 2 3 4'.
vers_min_centos_5="0 11"
vers_min_centos_6="0 6"
vers_min_centos_7="0"
vers_min_rhel_5="0 11"
vers_min_rhel_6="0 6"
vers_min_rhel_7="0 1"

#-------------------------------------------------------------------------------
#  Functions
#-------------------------------------------------------------------------------
loadDefaults() {
  # Load the paths (if they exist)
  if [ -f ${HOME}/.prep.conf ]; then
      . ${HOME}/.prep.conf
  else
    echo
    echo "The file ${HOME}/.prep.conf does not exist in your home."
    echo "The prep script creates a default template of this file when run."
    echo "Exiting..."
    exit 1
  fi
}

#-------------------------------------------------------------------------------
#  Main Script
#-------------------------------------------------------------------------------
# Get the GPG daemon running so we don't have to keep entering the password for
# the GPG key every time we sign a package
eval $(gpg-agent --daemon)

loadDefaults                                    # Load Default paths and vars

# At this point, all variables should be set. Print a usage message if the
# ${ARCHDIR} variable is not set (the last of the command-line variables).
if [ ! -d "$ARCHDIR" ] ; then
    echo 1>&2 "Usage: $0 <galera?> <enterprise?> <archive directory> [p8_dir]"
    echo 1>&2 "For <galera?> and <enterprise?> : yes or no"
    echo 1>&2 "[p8_dir] is optional"
    exit 1
fi

# After this point, we tread unset variables as an error
set -u
  # -u  Treat unset variables as an error when performing parameter expansion.
  #     An error message will be written to the standard error, and a
  #     non-interactive shell will exit.


for distro in ${distros}; do
  eval vers_maj=\$vers_maj_${distro}
  for ver_maj in ${vers_maj}; do
    #-------------------------------------------------------------------------------
    # The following section (the eval and the for loop) is where directories
    # are created and the files are copied over (in the embedded case
    # statement). The eval pulls in the correct architecture values, which are
    # then split into an array before acting on the information.
    #-------------------------------------------------------------------------------
    eval archs=\$archs_${distro}_${ver_maj}
    for arch_pair in ${archs}; do
      arch_array=(${arch_pair//:/ })
      mkdir -vp ${distro}/${ver_maj}/${arch_array[1]}
      ln -sv ${distro}/${ver_maj}/${arch_array[1]} ${distro}${ver_maj}-${arch_array[0]}
      ARCH=${arch_array[0]}
      REPONAME="${distro}${ver_maj}"

      case "${REPONAME}" in
        'rhel6')
          echo rsync -avP --keep-dirlinks ${ARCHDIR}/kvm-rpm-centos6-${ARCH}/ ./${REPONAME}-${ARCH}/
          ;;
        'centos7'|'rhel7')
          if [ "${ARCH}" = "amd64" ]; then
            echo rsync -avP --keep-dirlinks ${ARCHDIR}/kvm-rpm-centos7-${ARCH}/ ./${REPONAME}-${ARCH}/
          else
            echo "+ no packages for ${REPONAME}-${ARCH}"
          fi
          ;;
        'opensuse13'|'sles11')
          echo rsync -avP --keep-dirlinks ${ARCHDIR}/kvm-zyp-${REPONAME}-${ARCH}/ ./${REPONAME}-${ARCH}/
          ;;
        'sles12')
          if [ "${ARCH}" = "amd64" ]; then
            echo rsync -avP --keep-dirlinks ${ARCHDIR}/kvm-zyp-${REPONAME}-${ARCH}/ ./${REPONAME}-${ARCH}/
          else
            echo "+ no packages for ${REPONAME}-${ARCH}"
          fi
          ;;
        *)
          echo rsync -avP --keep-dirlinks ${ARCHDIR}/kvm-rpm-${REPONAME}-${ARCH}/ ./${REPONAME}-${ARCH}/
          ;;
      esac

    done

    #-------------------------------------------------------------------------------
    # This next section, between 'set +u' and 'set -u' creates symlinks for
    # various rhel and centos minor versions (e.g. 'centos/6.4') back to the
    # major version directory (e.g. 'centos/6'). The first set command turns
    # off the behavior where unset variables are treated as errors, and the
    # second one turns it back on. Code between the set commands is indented to
    # help make things more readable.
    #-------------------------------------------------------------------------------
    set +u
      eval vers_min=\$vers_min_${distro}_${ver_maj}
      if [ "${vers_min}" != "" ]; then
        for ver_min in $(seq ${vers_min}); do
          ln -sv ${ver_maj} ${distro}/${ver_maj}.${ver_min}
        done
      fi
    set -u

    # Add in special RHEL links
    if [ "${distro}" = "rhel" ]; then
      ln -sv ${ver_maj} ${distro}/${ver_maj}Server
      ln -sv ${ver_maj} ${distro}/${ver_maj}Client
    fi

  done
done
#exit 0 # Ending here for testing


# Copy over the packages
for REPONAME in ${dists}; do
  for ARCH in ${architectures}; do
    case "${REPONAME}" in
      'rhel6')
        #mkdir -vp "${REPONAME}-${ARCH}"
        rsync -avP --keep-dirlinks ${ARCHDIR}/kvm-rpm-centos6-${ARCH}/ ./${REPONAME}-${ARCH}/
        ;;
      'centos7'|'rhel7')
        if [ "${ARCH}" = "amd64" ]; then
          #mkdir -vp "${REPONAME}-${ARCH}"
          rsync -avP --keep-dirlinks ${ARCHDIR}/kvm-rpm-centos7-${ARCH}/ ./${REPONAME}-${ARCH}/
        else
          echo "+ no packages for ${REPONAME}-${ARCH}"
        fi
        ;;
      'opensuse13'|'sles11')
        #mkdir -vp "${REPONAME}-${ARCH}"
        rsync -avP --keep-dirlinks ${ARCHDIR}/kvm-zyp-${REPONAME}-${ARCH}/ ./${REPONAME}-${ARCH}/
        ;;
      'sles12')
        if [ "${ARCH}" = "amd64" ]; then
          #mkdir -vp "${REPONAME}-${ARCH}"
          rsync -avP --keep-dirlinks ${ARCHDIR}/kvm-zyp-${REPONAME}-${ARCH}/ ./${REPONAME}-${ARCH}/
        else
          echo "+ no packages for ${REPONAME}-${ARCH}"
        fi
        ;;
      *)
        #mkdir -vp "${REPONAME}-${ARCH}"
        rsync -avP --keep-dirlinks ${ARCHDIR}/kvm-rpm-${REPONAME}-${ARCH}/ ./${REPONAME}-${ARCH}/
        ;;
    esac

      # Add in custom jemalloc packages for distros that need them
      case "${REPONAME}-${ARCH}" in
        'opensuse13-x86'|'opensuse13-amd64'|'sles11-x86'|'sles11-amd64'|'sles12-amd64'|'sles12-x86')
          echo "no custom jemalloc packages for ${REPONAME}-${ARCH}"
          ;;
        'centos7-x86'|'rhel7-x86'|'fedora19-x86'|'fedora19-amd64'|'fedora20-x86'|'fedora20-amd64'|'fedora21-x86'|'fedora21-amd64')
          echo "no custom jemalloc packages for ${REPONAME}-${ARCH}"
          ;;
        * ) rsync -avP --keep-dirlinks ${jemalloc_dir}/jemalloc-${REPONAME}-${ARCH}-${suffix}/*.rpm ./${REPONAME}-${ARCH}/rpms/
          ;;
      esac

      # Add in nmap where needed
      case "${REPONAME}-${ARCH}" in
        #'sles12-amd64'|'sles12-x86')
        'sles12-amd64')
          rsync -avP --keep-dirlinks ${nmap_dir}/${ARCH}/${nmap_ver}-${suffix}/rpms/*.rpm ./${REPONAME}-${ARCH}/rpms/
          ;;
      esac

      # Copy in galera packages if requested
      if [ ${GALERA} = "yes" ]; then
        for gv in ${galera_versions}; do
          if [ "${ARCH}" = "amd64" ]; then
            if [ "${REPONAME}" = "centos5" ] || [ "${REPONAME}" = "rhel5" ]; then
              rsync -avP --keep-dirlinks ${galera_dir}/galera-${gv}-${suffix}/rpm/*rhel5*x86_64.rpm ./${REPONAME}-${ARCH}/rpms/
            elif [ "${REPONAME}" = "centos7" ] || [ "${REPONAME}" = "rhel7" ]; then
              rsync -avP --keep-dirlinks ${galera_dir}/galera-${gv}-${suffix}/rpm/*rhel7*x86_64.rpm ./${REPONAME}-${ARCH}/rpms/
            elif [ "${REPONAME}" = "fedora19" ] ; then
              rsync -avP --keep-dirlinks ${galera_dir}/galera-${gv}-${suffix}/rpm/*fc19*x86_64.rpm ./${REPONAME}-${ARCH}/rpms/
            elif [ "${REPONAME}" = "fedora20" ] ; then
              rsync -avP --keep-dirlinks ${galera_dir}/galera-${gv}-${suffix}/rpm/*fc20*x86_64.rpm ./${REPONAME}-${ARCH}/rpms/
            elif [ "${REPONAME}" = "sles11" ] ; then
              rsync -avP --keep-dirlinks ${galera_dir}/galera-${gv}-${suffix}/rpm/*sles11*x86_64.rpm ./${REPONAME}-${ARCH}/rpms/
            elif [ "${REPONAME}" = "sles12" ] ; then
              rsync -avP --keep-dirlinks ${galera_dir}/galera-${gv}-${suffix}/rpm/*sles12*x86_64.rpm ./${REPONAME}-${ARCH}/rpms/
            elif [ "${REPONAME}" = "opensuse13" ] ; then
              rsync -avP --keep-dirlinks ${galera_dir}/galera-${gv}-${suffix}/rpm/*sles13*x86_64.rpm ./${REPONAME}-${ARCH}/rpms/
            else
              rsync -avP --keep-dirlinks ${galera_dir}/galera-${gv}-${suffix}/rpm/*rhel6*x86_64.rpm ./${REPONAME}-${ARCH}/rpms/
            fi
          else
            if [ "${REPONAME}" = "centos5" ] || [ "${REPONAME}" = "rhel5" ]; then
              rsync -avP --keep-dirlinks ${galera_dir}/galera-${gv}-${suffix}/rpm/*rhel5*i386.rpm ./${REPONAME}-${ARCH}/rpms/
            elif [ "${REPONAME}" = "fedora19" ] ; then
              rsync -avP --keep-dirlinks ${galera_dir}/galera-${gv}-${suffix}/rpm/*fc19*i386.rpm ./${REPONAME}-${ARCH}/rpms/
            elif [ "${REPONAME}" = "fedora20" ] ; then
              rsync -avP --keep-dirlinks ${galera_dir}/galera-${gv}-${suffix}/rpm/*fc20*i686.rpm ./${REPONAME}-${ARCH}/rpms/
            elif [ "${REPONAME}" = "sles11" ] ; then
              rsync -avP --keep-dirlinks ${galera_dir}/galera-${gv}-${suffix}/rpm/*sles11*i586.rpm ./${REPONAME}-${ARCH}/rpms/
            elif [ "${REPONAME}" = "opensuse13" ] ; then
              rsync -avP --keep-dirlinks ${galera_dir}/galera-${gv}-${suffix}/rpm/*sles13*i586.rpm ./${REPONAME}-${ARCH}/rpms/
            elif [ "${REPONAME}" = "sles12" ] || [ "${REPONAME}" = "centos7" ] || [ "${REPONAME}" = "rhel7" ]; then
              echo "+ no packages for ${REPONAME}-${ARCH}"
            else
              rsync -avP --keep-dirlinks ${galera_dir}/galera-${gv}-${suffix}/rpm/*rhel6*i*86.rpm ./${REPONAME}-${ARCH}/rpms/
            fi
          fi
        done
      fi
  done
done




if [ "${ENTERPRISE}" = "yes" ]; then
  for P8_REPONAME in ${p8_dists}; do
    for P8_ARCH in ${p8_architectures}; do
        if [ "${P8_REPONAME}" = "rhel6" ]; then
          if [ "${P8_ARCH}" = "ppc64" ]; then
            #mkdir -vp "${P8_REPONAME}-${P8_ARCH}"
            rsync -avP --keep-dirlinks ${P8_ARCHDIR}/p8-rhel6-rpm/ ./${P8_REPONAME}-${P8_ARCH}/
          else
            echo "+ no packages for ${P8_REPONAME}-${P8_ARCH}"
          fi
        elif [ "${P8_REPONAME}" = "centos71" ] || [ "${P8_REPONAME}" = "rhel71" ]; then
          if [ "${P8_ARCH}" = "ppc64le" ]; then
            #mkdir -vp "${P8_REPONAME}-${P8_ARCH}"
            rsync -avP --keep-dirlinks ${P8_ARCHDIR}/p8-rhel71-rpm/ ./rhel7-${P8_ARCH}/
          else
            echo "+ no packages for ${P8_REPONAME}-${P8_ARCH}"
          fi
        elif [ "${P8_REPONAME}" = "centos7" ] || [ "${P8_REPONAME}" = "rhel7" ]; then
          if [ "${P8_ARCH}" = "ppc64" ]; then
            #mkdir -vp "${P8_REPONAME}-${P8_ARCH}"
            rsync -avP --keep-dirlinks ${P8_ARCHDIR}/p8-rhel7-rpm/ ./${P8_REPONAME}-${P8_ARCH}/
          else
            echo "+ no packages for ${P8_REPONAME}-${P8_ARCH}"
          fi
        elif [ "${P8_REPONAME}" = "sles12" ]; then
          if [ "${P8_ARCH}" = "ppc64le" ]; then
            #mkdir -vp "${P8_REPONAME}-${P8_ARCH}"
            rsync -avP --keep-dirlinks ${P8_ARCHDIR}/p8-suse12-rpm/ ./${P8_REPONAME}-${P8_ARCH}/
          else
            echo "+ no packages for ${P8_REPONAME}-${P8_ARCH}"
          fi
        fi

        # Add in custom jemalloc packages for distros that need them
        case "${P8_REPONAME}-${P8_ARCH}" in
          'centos7-ppc64'|'rhel7-ppc64'|'centos6-ppc64'|'rhel6-ppc64')
            rsync -avP --keep-dirlinks ${jemalloc_dir}/jemalloc-${P8_REPONAME}-${P8_ARCH}-${suffix}/*.rpm ./${P8_REPONAME}-${P8_ARCH}/rpms/
            ;;
          * ) 
            echo "no custom jemalloc packages for ${P8_REPONAME}-${P8_ARCH}"
            ;;
        esac

        # Add in advance-toolchain runtime for distros that need them
        case "${P8_REPONAME}-${P8_ARCH}" in
          'centos6-ppc64'|'rhel6-ppc64'|'centos7-ppc64'|'rhel7-ppc64'|'sles12-ppc64le')
            rsync -avP --keep-dirlinks ${at_dir}/${P8_REPONAME}-${P8_ARCH}-${suffix}/*runtime*.rpm ./${P8_REPONAME}-${P8_ARCH}/rpms/
            ;;
          'centos71-ppc64le'|'rhel71-ppc64le')
            rsync -avP --keep-dirlinks ${at_dir}/${P8_REPONAME}-${P8_ARCH}-${suffix}/*runtime*.rpm ./rhel7-${P8_ARCH}/rpms/
            ;;
          * ) 
            echo "no advance-toolchain packages for ${P8_REPONAME}-${P8_ARCH}"
            ;;
        esac

    done
  done
fi

# Sign all the rpms with the appropriate key
rpmsign --addsign --key-id=${gpg_key} $(find . -name '*.rpm')

for DIR in *-*; do
  if [ -d "${DIR}" ]; then
    # regenerate the md5sums.txt file (signing packages changes their checksum)
    cd ${DIR}
    pwd
    if [ -e md5sums.txt ]; then
      rm -v md5sums.txt
    fi
    md5sum $(find . -name '*.rpm') >> md5sums.txt
    md5sum -c md5sums.txt
    cd ..

    # Create the repository and sign the repomd.xml file
    case ${DIR} in
      'centos5-amd64'|'centos5-x86'|'rhel5-amd64'|'rhel5-x86')
        # CentOS & RHEL 5 don't support newer sha256 checksums
        createrepo -s sha --database --pretty ${DIR}
        ;;
      *)
        createrepo --database --pretty ${DIR}
        ;;
    esac
    
    gpg --detach-sign --armor -u ${gpg_key} ${DIR}/repodata/repomd.xml 

    # Add a README to the srpms directory
    mkdir -vp ${DIR}/srpms
    echo "Why do MariaDB RPMs not include the source RPM (SRPMS)?
https://mariadb.com/kb/en/why-do-mariadb-rpms-not-include-the-source-rpm-srpms
" > ${DIR}/srpms/README
  fi
done

# vim: filetype=sh
