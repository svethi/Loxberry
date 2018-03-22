#!/usr/bin/perl

# Input parameters from loxberryupdate.pl:
# 	release: the final version update is going to (not the version of the script)
#   logfilename: The filename of LoxBerry::Log where the script can append
#   updatedir: The directory where the update resides
#   cron: If 1, the update was triggered automatically by cron

use LoxBerry::System;
use LoxBerry::Log;
use CGI;

my $cgi = CGI->new;
 

# Initialize logfile and parameters
	my $logfilename;
	if ($cgi->param('logfilename')) {
		$logfilename = $cgi->param('logfilename');
	}
	my $log = LoxBerry::Log->new(
			package => 'LoxBerry Update',
			name => 'update',
			filename => $logfilename,
			logdir => "$lbslogdir/loxberryupdate",
			loglevel => 7,
			stderr => 1,
			append => 1,
	);
	$logfilename = $log->filename;

	if ($cgi->param('updatedir')) {
		$updatedir = $cgi->param('updatedir');
	}
	my $release = $cgi->param('release');

# Finished initializing
# Start program here
########################################################################

my $errors = 0;
LOGOK "Update script $0 started.";

#
# Upgrading usb-mount
#
LOGINF "Upgrading usb-mount to enable mountings over fstab";

if ( -e "/etc/udev/rules.d/99-usbmount.rules" ) {
	qx {rm -f /etc/udev/rules.d/99-usbmount.rules };
}
open(F,">/etc/udev/rules.d/99-usbmount.rules");
print F <<EOF;
KERNEL=="sd[a-z]*[0-9]", SUBSYSTEMS=="usb", ACTION=="add", RUN+="/opt/loxberry/sbin/usb-mount.sh chkadd %k"
KERNEL=="sd[a-z]*[0-9]", SUBSYSTEMS=="usb", ACTION=="remove", RUN+="/bin/systemctl stop usb-mount@%k.service"
EOF
close(F);

LOGINF "Removing nofail from fstab";

qx { sed 's/,nofail//g' /etc/fstab > fstab.new };
qx { cp /etc/fstab /etc/fstab.bak };
qx { cat /etc/fstab.new > /etc/fstab };
qx { rm /etc/fstab.new };

#
# Upgrade Raspbian
#
LOGINF "Upgrading system to latest Raspbian release. This may take a long time - please be patient...";

my $output = qx { /usr/bin/dpkg --configure -a };
my $exitcode  = $? >> 8;
if ($exitcode != 0) {
        LOGERR "Error configuring dkpg with /usr/bin/dpkg --configure -a - Error $exitcode";
        LOGDEB $output;
                $errors++;
} else {
        LOGOK "Configuring dpkg successfully.";
}
$output = qx { DEBIAN_FRONTEND=noninteractive /usr/bin/apt-get -q -y update };
$exitcode  = $? >> 8;
if ($exitcode != 0) {
        LOGERR "Error updating apt database - Error $exitcode";
                LOGDEB $output;
        $errors++;
} else {
        LOGOK "Apt database updated successfully.";
}
$output = qx { DEBIAN_FRONTEND=noninteractive /usr/bin/apt-get -q -y upgrade };
$exitcode  = $? >> 8;
if ($exitcode != 0) {
        LOGERR "Error upgrading system - Error $exitcode";
                LOGDEB $output;
        $errors++;
} else {
        LOGOK "System upgrade successfully.";
}

#
# Update Kernel and Firmware
#
if (-e "$lbhomedir/config/system/is_raspberry.cfg") {
	LOGINF "Upgrading system kernel and firmware. This may take a long time - please be patient...";

	my $output = qx { SKIP_WARNING=1 /usr/bin/rpi-update };
	my $exitcode  = $? >> 8;
	if ($exitcode != 0) {
        	LOGERR "Error upgrading kernel and firmware - Error $exitcode";
        	LOGDEB $output;
                $errors++;
	} else {
        	LOGOK "Upgrading kernel and firmware successfully.";
	}
}


## If this script needs a reboot, a reboot.required file will be created or appended
LOGWARN "Update file $0 requests a reboot of LoxBerry. Please reboot your LoxBerry after the installation has finished.";
reboot_required("LoxBerry Update requests a reboot.");

LOGOK "Update script $0 finished." if ($errors == 0);
LOGERR "Update script $0 finished with errors." if ($errors != 0);

# End of script
exit($errors);


sub delete_directory
{
	
	require File::Path;
	my $delfolder = shift;
	
	if (-d $delfolder) {   
		rmtree($delfolder, {error => \my $err});
		if (@$err) {
			for my $diag (@$err) {
				my ($file, $message) = %$diag;
				if ($file eq '') {
					LOGERR "     Delete folder: general error: $message";
				} else {
					LOGERR "     Delete folder: problem unlinking $file: $message";
				}
			}
		return undef;
		}
	}
	return 1;
}


####################################################################
# Copy a file or dir from updatedir to lbhomedir including error handling
# Parameter:
#	file/dir starting from ~ 
#   (without /opt/loxberry, with leading /)
####################################################################
sub copy_to_loxberry
{
	my ($destparam) = @_;
		
	my $destfile = $lbhomedir . $destparam;
	my $srcfile = $updatedir . $destparam;
		
	if (! -e $srcfile) {
		LOGERR "$srcfile does not exist";
		$errors++;
		return;
	}
	
	my $output = qx { cp -f $srcfile $destfile };
	my $exitcode  = $? >> 8;

	if ($exitcode != 0) {
		LOGERR "Error copying $destparam - Error $exitcode";
		LOGINF "Message: $output";
		$errors++;
	} else {
		LOGOK "$destparam installed.";
	}
}

