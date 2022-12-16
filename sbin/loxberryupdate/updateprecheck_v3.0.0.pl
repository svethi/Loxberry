#!/usr/bin/perl

# Input parameters from loxberryupdate.pl:
# 	release: the final version update is going to (not the version of the script)
#   logfilename: The filename of LoxBerry::Log where the script can append
#   updatedir: The directory where the update resides
#   cron: If 1, the update was triggered automatically by cron

use LoxBerry::Update;

init();

#
# Stop the update if the boot partition is too small
#
use LoxBerry::System;
my %folderinfo = LoxBerry::System::diskspaceinfo('/boot');
if ($folderinfo{size} < 200000) {
	LOGCRIT "Your boot partition is too small for LoxBerry 3.0 (needed: 256 MB). Current size is: " . LoxBerry::System::bytes_humanreadable($folderinfo{size}, "K") . " Create a backup with the new LoxBerry Backup Widget. The backups will include a bigger boot partition, which is sufficient for LB3.0";
	exit (1);
}

exit (0);