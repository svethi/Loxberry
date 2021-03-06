#!/usr/bin/perl

# Copyright 2016 Michael Schlenstedt, michael@loxberry.de
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#     http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


##########################################################################
# Modules
##########################################################################

use File::Path qw(make_path remove_tree);
use Digest::MD5 qw(md5_hex);
use Encode qw(encode_utf8);
use LoxBerry::System;
use LoxBerry::Log;
use CGI;
#use LoxBerry::Web;
use version;
#use warnings;
#use strict;

# Version of this script
my $version = "1.4.0.6";

if ($<) {
	print "This script has to be run as root or with sudo.\n";
	exit (1);
}

my $exitcode;

##########################################################################
# Variables / Commandline
##########################################################################

# Command line options
my $cgi = CGI->new;
$cgi->import_names('R');

# Command line or CGI?
if ( $R::cgi ) {
	our $is_cgi = 1;
	print "We are in CGI mode.\n";
} else {
	our $is_cgi = 0;
	print "We are in Command line mode.\n";
}

##########################################################################
# Read Settings
##########################################################################

my $bins = LoxBerry::System::get_binaries();
my $bashbin         = $bins->{BASH};
my $aptbin          = $bins->{APT};
my $sudobin         = $bins->{SUDO};
my $chmodbin        = $bins->{CHMOD};
my $chownbin        = $bins->{CHOWN};
my $unzipbin        = $bins->{UNZIP};
my $findbin         = $bins->{FIND};
my $grepbin         = $bins->{GREP};
my $dpkgbin         = $bins->{DPKG};
my $dos2unix        = $bins->{DOS2UNIX};

##########################################################################
# Language Settings
##########################################################################

my $lang = lblanguage();

# Read phrases from language_LANG.ini
our %SL = LoxBerry::System::readlanguage(undef);

##########################################################################
# Checks
##########################################################################

my $message;
my @errors;
my @warnings;
if ( $R::action ne "install" && $R::action ne "uninstall" && $R::action ne "autoupdate" ) {
  $message =  "$SL{'PLUGININSTALL.ERR_ACTION'}";
  &logfail;
}
if ( $R::action eq "install" ) {
  if ( (!$R::folder && !$R::file) || ($R::folder && $R::file) ) {
    $message =  "$SL{'PLUGININSTALL.ERR_NOFOLDER_OR_ZIP'}";
    &logfail;
  }
  if ( !$R::pin && $R::action ne "autoupdate" ) {
    $message =  "$SL{'PLUGININSTALL.ERR_NOPIN'}";
    &logfail;
  }
}
if ( $R::action eq "uninstall" || $R::action eq "autoupdate" ) {
  if ( !$R::pid ) {
    $message =  "$SL{'PLUGININSTALL.ERR_NOPID'}";
    &logfail;
  }
}

# ZIP or Folder mode?
my $zipmode = defined $R::file ? 1 : 0;

# Which Action should be perfomred?
if ($R::action eq "install" || $R::action eq "autoupdate" ) {
  &install;
}
if ($R::action eq "uninstall" ) {
  &uninstall;
}

exit (0);

#####################################################
# UnInstall
#####################################################

sub uninstall {

our $pid = $R::pid;
my $found = 0;
our $pname;
our $pfolder;
open(F,"<$lbsdatadir/plugindatabase.dat") or ($openerr = 1);
  if ($openerr) {
    $message =  "$SL{'PLUGININSTALL.ERR_DATABASE'}";
    &logfail;
  }
  @data = <F>;
  foreach (@data){
    s/[\n\r]//g;
    # Comments
    if ($_ =~ /^\s*#.*/) {
      next;
    }
    @fields = split(/\|/);
    if ($pid eq @fields[0]) {
      $found = 1;
      $pname   = @fields[4];
      $pfolder = @fields[5];
    }
  }
close (F);

if ( !$found ) {
  $message =  "$SL{'PLUGININSTALL.ERR_PIDNOTEXIST'}";
  &logfail;
}

&purge_installation ("all");

# Purge plugin notifications
LoxBerry::Log::delete_notifications($pfolder) if ($pfolder);

# Remove Lock
LoxBerry::System::unlock( lockfile => 'plugininstall' );

exit (0);

}

#####################################################
# Install
#####################################################

sub install {

# Choose random temp filename
if ( !$R::tempfile ) {;
	our $tempfile = &generate(10);
} else {
	our $tempfile = $R::tempfile;
}
# Create status and logfile
our $logfile = "/tmp/$tempfile.log";
our $statusfile = "/tmp/$tempfile.status";
if (-e "$statusfile") {
  $message =  "$SL{'PLUGININSTALL.ERR_TEMPFILES_EXISTS'}";
  &logfail;
}

$message =  "Statusfile: $statusfile";
&loginfo;
open (F, ">$statusfile");
flock(F,2);
  print F "1";
flock(F,8);
close (F);


# Check secure PIN
if ( $R::action ne "autoupdate" ) {
	my $pin = $R::pin;

	if ( LoxBerry::System::check_securepin($pin) ) {
		$message =  "$SL{'PLUGININSTALL.ERR_SECUREPIN_WRONG'}";
		&logfail;
	}
}

# Check if plugin is installed (autoupdate)
if ( $R::action eq "autoupdate" ) {

	my $pid = $R::pid;
	my $found = 0;
	my @plugins = LoxBerry::System::get_plugins();

	foreach (@plugins) {
		if ( $_->{PLUGINDB_MD5_CHECKSUM} eq $pid ) {
			$found = 1;
		}
	}
	if ( !$found ) {
	  $message =  "$SL{'PLUGININSTALL.ERR_PIDNOTEXIST'}";
	  &logfail;
	}

}

if (!$zipmode) { 
  our $tempfolder = $R::folder;
  if (!-e $tempfolder) {
    $message =  "$SL{'PLUGININSTALL.ERR_FOLDER_DOESNT_EXIST'}";
    &logfail;
  }
} else {
  our $tempfolder = "/tmp/uploads/$tempfile";
  if (!-e $R::file) {
    $message =  "$SL{'PLUGININSTALL.ERR_FILE_DOESNT_EXIST'}";
    &logfail;
  }
  make_path("$tempfolder" , {chmod => 0755, owner=>'loxberry', group=>'loxberry'});
}
$tempfolder =~ s/(.*)\/$/$1/eg; # Clean trailing /
$message =  "Temp Folder: $tempfolder";
&loginfo;

$message = "Logfile: $logfile";
&loginfo;
if ( ! $is_cgi ) {
	open (F, ">$logfile");
	flock(F,2);
	  print F "";
	flock(F,8);
	close (F);
}

# Check free space in tmp
my $pluginsize;
my %folderinfo;
if ( $zipmode ) {
	$pluginsize = `$unzipbin -l $R::file | tail -1 | xargs | cut -d' ' -f1`;
	$pluginsize = $pluginsize / 1000; # kBytes
	%folderinfo = LoxBerry::System::diskspaceinfo("/tmp");
	if ($folderinfo{available} < $pluginsize * 1.1) { # exstracted size + 10%
		$message =  "$SL{'PLUGININSTALL.ERR_NO_SPACE_IN_TMP'} " . $folderinfo{available} . " kB";
		&logfail;
	}
} else {
	$pluginsize = `du -bs $tempfolder | tail -1 | xargs | cut -d' ' -f1`;
	$pluginsize = $pluginsize / 1000; # kBytes
}

# Check free space in $lbhomedir
%folderinfo = LoxBerry::System::diskspaceinfo($lbhomedir);
if ($folderinfo{available} < $pluginsize * 1.1) { # exstracted size + 10%
	$message =  "$SL{'PLUGININSTALL.ERR_NO_SPACE_IN_ROOT'} " . $folderinfo{available} . " kB";
	&logfail;
}

# Locking
$message = "$SL{'PLUGININSTALL.INF_LOCKING'}";
&loginfo;
eval {
	my $lockstate = LoxBerry::System::lock( lockfile => 'plugininstall', wait => 600 );

	if ($lockstate) {
		$message = "$SL{'PLUGININSTALL.ERR_LOCKING'}";
		&logerr;
		$message = "$SL{'PLUGININSTALL.ERR_LOCKING_REASON'} $lockstate";
		&logfail;
	}
};

$message = "$SL{'PLUGININSTALL.OK_LOCKING'}";
&logok;

# Starting
$message =  "$SL{'PLUGININSTALL.INF_START'}";
&loginfo;

# UnZipping
if ( $zipmode ) {

  $message =  "$SL{'PLUGININSTALL.INF_EXTRACTING'}";
  &loginfo;

  $message = "Command: $sudobin -n -u loxberry $unzipbin -d $tempfolder $R::file";
  &loginfo;

  system("$sudobin -n -u loxberry $unzipbin -d $tempfolder $R::file 2>&1");
  if ($? ne 0) {
    $message =  "$SL{'PLUGININSTALL.ERR_EXTRACTING'}";
    &logfail;
  } else {
    $message =  "$SL{'PLUGININSTALL.OK_EXTRACTING'}";
    &logok;
  }

}

# Check for plugin.cfg
if (!-f "$tempfolder/plugin.cfg") {
  $exists = 0;
  opendir(DIR, "$tempfolder");
    @data = readdir(DIR);
  closedir(DIR);
  foreach(@data) {
    if (-f "$tempfolder/$_/plugin.cfg" && $_ ne "." && $_ ne "..") {
      $tempfolder = $tempfolder . "/$_";
      $exists = 1;
      last;
    }
  }
  if (!$exists) {
    $message =  "$SL{'PLUGININSTALL.ERR_ARCHIVEFORMAT'}";
    &logfail;
  }
}

# Read Plugin-Config
eval {
        our $pcfg = new Config::Simple("$tempfolder/plugin.cfg") or  die Config::Simple->error();
};
if ($@) {
        $message = "$SL{'PLUGININSTALL.ERR_UNKNOWN_FORMAT_PLUGINCFG'}";
        &logfail;
}

our $pauthorname      = $pcfg->param("AUTHOR.NAME");
our $pauthoremail     = $pcfg->param("AUTHOR.EMAIL");
our $pversion         = $pcfg->param("PLUGIN.VERSION");
our $pname            = $pcfg->param("PLUGIN.NAME");
our $ptitle           = $pcfg->param("PLUGIN.TITLE");
our $pfolder          = $pcfg->param("PLUGIN.FOLDER");
our $pautoupdates     = $pcfg->param("AUTOUPDATE.AUTOMATIC_UPDATES");
our $preleasecfg      = $pcfg->param("AUTOUPDATE.RELEASECFG");
our $pprereleasecfg   = $pcfg->param("AUTOUPDATE.PRERELEASECFG");
our $pinterface       = $pcfg->param("SYSTEM.INTERFACE");
our $preboot          = $pcfg->param("SYSTEM.REBOOT");
our $pcustomlog       = $pcfg->param("SYSTEM.CUSTOM_LOGLEVELS");
our $plbmin           = $pcfg->param("SYSTEM.LB_MINIMUM");
our $plbmax           = $pcfg->param("SYSTEM.LB_MAXIMUM");
our $parch            = $pcfg->param("SYSTEM.ARCHITECTURE");

# Filter
$pname =~ tr/A-Za-z0-9_-//cd;
$pfolder =~ tr/A-Za-z0-9_-//cd;
if (length($ptitle) > 25) {
  $ptitle = substr($ptitle,0,22);
  $ptitle = $ptitle . "...";
}

if ( is_disabled ($pautoupdates) || $preleasecfg eq "" ) {
  $preleasecfg = "";
  $pprereleasecfg = "";
  $pautoupdates = "False";
} else {
  $pautoupdates = "True";
}

if ( is_disabled($parch) || $parch eq "" ) {
  $parch = "False";
}

if ( is_disabled($preboot) || $preboot eq "" ) {
  $preboot = "False";
} else {
  $preboot = "True";
}

if ( is_disabled($pcustomlog) || $pcustomlog eq "" ) {
  $pcustomlog = "False";
} else {
  $pcustomlog = "True";
}

if ( is_disabled($plbmin) || $plbmin eq "" ) {
  $plbmin = "False";
}

if ( is_disabled($plbmax) || $plbmax eq "" ) {
  $plbmax = "False";
}

$message = "Author:       $pauthorname";
&loginfo;
$message = "Email:        $pauthoremail";
&loginfo;
$message = "Version:      $pversion";
&loginfo;
$message = "Name:         $pname";
&loginfo;
$message = "Folder:       $pfolder";
&loginfo;
$message = "Title:        $ptitle";
&loginfo;
$message = "Autoupdate:   $pautoupdates";
&loginfo;
$message = "Release:      $preleasecfg";
&loginfo;
$message = "Prerelease:   $pprereleasecfg";
&loginfo;
$message = "Reboot:       $preboot";
&loginfo;
$message = "Min LB Vers:  $plbmin";
&loginfo;
$message = "Max LB Vers:  $plbmax";
&loginfo;
$message = "Architecture: $parch";
&loginfo;
$message = "Custom Log:   $pcustomlog";
&loginfo;
$message = "Interface:    $pinterface";
&loginfo;

# Create Logfile with lib to have it in database
my $log = LoxBerry::Log->new(
                package => 'Plugin Installation',
                name => 'Installation',
                filename => "$lbhomedir/log/system/plugininstall/$pname.log",
                loglevel => 7,
);
LOGSTART "LoxBerry Plugin Installation $ptitle";

# Use 0/1 for enabled/disabled from here on
$pautoupdates = is_disabled($pautoupdates) ? 0 : 1;
$preboot = is_disabled($preboot) ? 0 : 1;
$pcustomlog = is_disabled($pcustomlog) ? -1 : 3; # -1 = disabled, 3 = Default

# Some checks
if (!$pauthorname || !$pauthoremail || !$pversion || !$pname || !$ptitle || !$pfolder || !$pinterface) {
  $message =  "$SL{'PLUGININSTALL.ERR_PLUGINCFG'}";
  &logfail;
}  else {
  $message =  "$SL{'PLUGININSTALL.OK_PLUGINCFG'}";
  &logok;
}

if ( $pinterface ne "1.0" && $pinterface ne "2.0" ) {
  $message =  "$SL{'PLUGININSTALL.ERR_UNKNOWNINTERFACE'}";
  &logfail; 
}

if ( $pinterface eq "1.0" ) {
  $message =  "*** DEPRECIATED *** This Plugin uses the outdated PLUGIN Interface V1.0. It will be compatible with this Version of LoxBerry but may not work with the next Major LoxBerry release! Please inform the PLUGIN Author at $pauthoremail";
  &logwarn; 
  push(@warnings,"PLUGININTERFACE: $message");
  # Always reboot with V1 plugins
  $preboot = 1;
}

# Arch check
if ( is_enabled($parch) ) {
  my $archcheck = 0;
  foreach (split(/,/,$parch)){
    if (-e "$lbsconfigdir/is_$_.cfg") {
      $archcheck = 1;
      $message =  "$SL{'PLUGININSTALL.OK_ARCH'}";
      &logok;
      last;
    } 
  }
  if (!$archcheck) {
    $message =  "$SL{'PLUGININSTALL.ERR_ARCH'}";
    &logfail;
  }
}

# Version check
my $versioncheck = 0;
if (version::is_lax(vers_tag(LoxBerry::System::lbversion()))) {
  $versioncheck = 1;
  our $lbversion = version->parse(vers_tag(LoxBerry::System::lbversion()));
  $message =  $SL{'PLUGININSTALL.INF_LBVERSION'} . $lbversion;
  &loginfo;
} else {
  $versioncheck = 0;
}

if ( !is_disabled($plbmin) && $versioncheck) {

  if ( (version::is_lax(vers_tag($plbmin))) ) {
    $plbmin = version->parse(vers_tag($plbmin));
    $message =  $SL{'PLUGININSTALL.INF_MINVERSION'} . $plbmin;
    &loginfo;
	if ($lbversion < $plbmin) {
		my $generalcfg = new Config::Simple("$lbsconfigdir/general.cfg");
		if ($generalcfg->param("UPDATE.RELEASETYPE") and $generalcfg->param("UPDATE.RELEASETYPE") eq "latest") {
			$message =  $SL{'PLUGININSTALL.INF_MINVERSION'} . $plbmin;
			push(@warnings, "$message");
			&logwarn;
			$message = "This plugin requests a newer LoxBerry version than installed. As you have set LoxBerry Update ";
			push(@warnings, "$message");
			&logwarn;
			$message = "to 'Latest commit', this plugin installation is allowed at your own risk. To test this plugin, you should ";
			push(@warnings, "$message");
			$logwarn;
			$message = "now also run LoxBerry Update. Don't bother the plugin developer if you haven't done so. Happy testing!";
			push(@warnings, "$message");
			&logwarn;
		} else {
			$message =  "$SL{'PLUGININSTALL.ERR_MINVERSION'}";
			&logfail;
		}
    } else {
		$message =  "$SL{'PLUGININSTALL.OK_MINVERSION'}";
		&logok;
    }
  } 

}

if ( !is_disabled($plbmax) && $versioncheck) {

  if ( (version::is_lax(vers_tag($plbmax))) ) {
    $plbmax = version->parse(vers_tag($plbmax));
    $message =  $SL{'PLUGININSTALL.INF_MAXVERSION'} . $plbmax;
    &loginfo;

    if ($lbversion > $plbmax) {
		my $generalcfg = new Config::Simple("$lbsconfigdir/general.cfg");
		if ($generalcfg->param("UPDATE.RELEASETYPE") and $generalcfg->param("UPDATE.RELEASETYPE") eq "latest") {
			$message =  $SL{'PLUGININSTALL.INF_MAXVERSION'} . $plbmin;
			push(@warnings, "$message");
			&logwarn;
			$message = "This plugin requests an older LoxBerry version than installed. As you have set LoxBerry Update ";
			push(@warnings, "$message");
			&logwarn;
			$message = "to 'Latest commit', this plugin installation is allowed at your own risk. Don't bother the plugin ";
			push(@warnings, "$message");
			&logwarn;
			$message = "developer if he hadn't asked you to do so. Happy testing!";
			push(@warnings, "$message");
			&logwarn;
		} else {
			$message =  "$SL{'PLUGININSTALL.ERR_MAXVERSION'}";
			&logfail;
		}
    } else {
		$message =  "$SL{'PLUGININSTALL.OK_MAXVERSION'}";
		&logok;
    }
  }

}

# Create MD5 Checksum
our $pmd5checksum = md5_hex(encode_utf8("$pauthorname$pauthoremail$pname$pfolder"));

# Read Plugin Database
my $openerr = 0;
if (!-e "$lbsdatadir/plugindatabase.dat") {
  $message =  "$SL{'PLUGININSTALL.ERR_DATABASE'}";
  &logfail;
}
my @pnames;
my @pfolders;
my $isupgrade = 0;
open(F,"+<$lbsdatadir/plugindatabase.dat") or ($openerr = 1);
  flock(F,2);
  if ($openerr) {
    $message =  "$SL{'PLUGININSTALL.ERR_DATABASE'}";
    &logfail;
  }
  my @data = <F>;
  seek(F,0,0);
  truncate(F,0);
  foreach (@data){
    s/[\n\r]//g;
    # Comments
    if ($_ =~ /^\s*#.*/) {
      print F "$_\n";
      next;
    }
    my @fields = split(/\|/);
    # If this is an upgrade use existing data
    if (@fields[0] eq $pmd5checksum) {
      $isupgrade = 1;
      if ( is_enabled($pautoupdates) && @fields[8] > $pautoupdates ) {
        $pautoupdates = @fields[8] 
      };
      if ( $pcustomlog == 3 && @fields[11] > -1 ) {
        $pcustomlog = @fields[11];
      }
      print F "@fields[0]|@fields[1]|@fields[2]|$pversion|@fields[4]|@fields[5]|$ptitle|$pinterface|$pautoupdates|$preleasecfg|$pprereleasecfg|$pcustomlog\n";
      $pname = @fields[4];
      $pfolder = @fields[5];
      $message =  "$SL{'PLUGININSTALL.INF_ISUPDATE'}";
      &loginfo;
    } else {
      print F "$_\n";
      push(@pnames,@fields[4]);
      push(@pfolders,@fields[5]);
    }
  }
  # If it is a new installation, make a new databaseentry
  if (!$isupgrade) {
    # Find "free" folder and name
    my $exists = 0;
    my $i;
    my $i1;
    for ($i=0;$i<=100;$i++){
      foreach (@pnames) {
        if ( ($_ eq $pname && $i == 1) || $_ eq $pname.sprintf("%02d", $i)) {
          $exists = 1;
        }
      }
      if (!$exists) {
        last;
      } else {
        $exists = 0;
      }
    }
    if ($i1 > 0) {
      $pname = $pname.sprintf("%02d", $i);
    }
    $exists = 0;
    for ($i1=0;$i1<=100;$i1++){
      foreach (@pfolders) {
        if ( ($_ eq $pfolder && $i1 == 1) || $_ eq $pfolder.sprintf("%02d", $i1)) {
          $exists = 1;
        }
      }
      if (!$exists) {
        last;
      } else {
        $exists = 0;
      }
    }
    if ($i1 > 0) {
      $pfolder = $pfolder.sprintf("%02d", $i1);
    }
    # Ok?
    if ($i < 100 && $i1 < 100) {
      $message =  "$SL{'PLUGININSTALL.OK_DBENTRY'}";
      &logok;
      $message = $SL{'PLUGININSTALL.INF_PNAME_IS'} . " $pname";
      &loginfo;
      $message = $SL{'PLUGININSTALL.INF_PFOLDER_IS'} . " $pfolder";
      &loginfo;
    } else {
      $message =  "$SL{'PLUGININSTALL.ERR_DBENTRY'}";
      &logfail;
    }
    print F "$pmd5checksum|$pauthorname|$pauthoremail|$pversion|$pname|$pfolder|$ptitle|$pinterface|$pautoupdates|$preleasecfg|$pprereleasecfg|$pcustomlog\n";
  }
  flock(F,8);
close (F);

# Sort Plugindatabase
&sort_plugins;

# Create shadow plugindatabase.dat and backup of plugindatabase
$message = $SL{'PLUGININSTALL.INF_SHADOWDB'};
&loginfo;
system("cp -v $lbsdatadir/plugindatabase.dat $lbsdatadir/plugindatabase.dat- 2>&1");
&setrights ("644", "0", "$lbsdatadir/plugindatabase.dat-", "PLUGIN DATABASE");
&setowner ("root", "0", "$lbsdatadir/plugindatabase.dat-", "PLUGIN DATABASE");
system("cp -v $lbsdatadir/plugindatabase.dat $lbsdatadir/plugindatabase.bkp 2>&1");
&setrights ("644", "0", "$lbsdatadir/plugindatabase.bkp", "PLUGIN DATABASE");
&setowner ("loxberry", "0", "$lbsdatadir/plugindatabase.bkp", "PLUGIN DATABASE");

# Starting installation

# Checking for hardcoded /opt/loxberry strings
if ( $pinterface ne "1.0" ) {
	my $chkhcpath = `$findbin $tempfolder -type f ! -iname '*.md' ! -iname '*.html' ! -iname '*.txt' ! -iname '*.dat' ! -iname '*.log' -exec $grepbin -li '/opt/loxberry' {} \\;`;
	if ($chkhcpath) {
	    $message =  $SL{'PLUGININSTALL.WARN_HARDCODEDPATHS'} . $pauthoremail;
	    &logwarn;
	    push(@warnings,"HARDCODED PATH'S: $message");
	    print "$chkhcpath";
	}
}

# Replacing Environment strings
$message =  "$SL{'PLUGININSTALL.INF_REPLACEENVIRONMENT'}";
&loginfo;
if (-e "$tempfolder" ) {
  &replaceenv ("loxberry", "1", "$tempfolder");
}

# Executing DOS2UNIX for all pluginfiles
$message =  "$SL{'PLUGININSTALL.INF_DOS2UNIX'}";
&loginfo;
if (-e "$tempfolder" ) {
  &dos2unix ("loxberry", "1", "$tempfolder");
}

# Executing preroot script
if (-f "$tempfolder/preroot.sh") {
  $message =  "$SL{'PLUGININSTALL.INF_START_PREROOT'}";
  &loginfo;

  $message = "Command: cd \"$tempfolder\" && \"$tempfolder/preroot.sh\" \"$tempfile\" \"$pname\" \"$pfolder\" \"$pversion\" \"$lbhomedir\" \"$tempfolder\"";
  &loginfo;

  system("$sudobin -n -u loxberry $chmodbin -v a+x \"$tempfolder/preroot.sh\" 2>&1");
  system("cd \"$tempfolder\" && \"$tempfolder/preroot.sh\" \"$tempfile\" \"$pname\" \"$pfolder\" \"$pversion\" \"$lbhomedir\" \"$tempfolder\" 2>&1");
  $exitcode  = $? >> 8;
  if ($exitcode eq 1) {
    $message =  "$SL{'PLUGININSTALL.ERR_SCRIPT'}";
    &logerr; 
    push(@errors,"PREROOT: $message");
  } 
  elsif ($exitcode > 1) {
    $message =  "$SL{'PLUGININSTALL.FAIL_SCRIPT'}";
    &logfail; 
  }
  else {
    $message =  "$SL{'PLUGININSTALL.OK_SCRIPT'}";
    &logok;
  }
}

# Executing preupgrade script
if ($isupgrade) {
  if (-f "$tempfolder/preupgrade.sh") {

    $message =  "$SL{'PLUGININSTALL.INF_START_PREUPGRADE'}";
    &loginfo;

    $message = "Command: cd \"$tempfolder\" && $sudobin -n -u loxberry \"$tempfolder/preupgrade.sh\" \"$tempfile\" \"$pname\" \"$pfolder\" \"$pversion\" \"$lbhomedir\" \"$tempfolder\"";
    &loginfo;

    system("$sudobin -n -u loxberry $chmodbin -v a+x \"$tempfolder/preupgrade.sh\" 2>&1");
    system("cd \"$tempfolder\" && $sudobin -n -u loxberry \"$tempfolder/preupgrade.sh\" \"$tempfile\" \"$pname\" \"$pfolder\" \"$pversion\" \"$lbhomedir\" \"$tempfolder\" 2>&1");
    $exitcode  = $? >> 8;
    if ($exitcode eq 1) {
      $message =  "$SL{'PLUGININSTALL.ERR_SCRIPT'}";
      &logerr; 
      push(@errors,"PREUPGRADE: $message");
    } 
    elsif ($exitcode > 1) {
      $message =  "$SL{'PLUGININSTALL.FAIL_SCRIPT'}";
      &logfail; 
    }
    else {
      $message =  "$SL{'PLUGININSTALL.OK_SCRIPT'}";
      &logok;
    }
  }
  # Purge old installation
  $message =  "$SL{'PLUGININSTALL.INF_REMOVING_OLD_INSTALL'}";
  &loginfo;

  &purge_installation;
}

# Executing preinstall script
if (-f "$tempfolder/preinstall.sh") {
  $message =  "$SL{'PLUGININSTALL.INF_START_PREINSTALL'}";
  &loginfo;

  $message = "Command: cd \"$tempfolder\" && $sudobin -n -u loxberry \"$tempfolder/preinstall.sh\" \"$tempfile\" \"$pname\" \"$pfolder\" \"$pversion\" \"$lbhomedir\" \"$tempfolder\"";
  &loginfo;

  system("$sudobin -n -u loxberry $chmodbin -v a+x \"$tempfolder/preinstall.sh\" 2>&1");
  system("cd \"$tempfolder\" && $sudobin -n -u loxberry \"$tempfolder/preinstall.sh\" \"$tempfile\" \"$pname\" \"$pfolder\" \"$pversion\" \"$lbhomedir\" \"$tempfolder\" 2>&1");
  $exitcode  = $? >> 8;
  if ($exitcode eq 1) {
    $message =  "$SL{'PLUGININSTALL.ERR_SCRIPT'}";
    &logerr; 
    push(@errors,"PREINSTALL: $message");
  } 
  elsif ($exitcode > 1) {
    $message =  "$SL{'PLUGININSTALL.FAIL_SCRIPT'}";
    &logfail; 
  }
  else {
    $message =  "$SL{'PLUGININSTALL.OK_SCRIPT'}";
    &logok;
  }
}  

# Copy Config files
make_path("$lbhomedir/config/plugins/$pfolder" , {chmod => 0755, owner=>'loxberry', group=>'loxberry'});
if (!&is_folder_empty("$tempfolder/config")) {
  $message =  "$SL{'PLUGININSTALL.INF_CONFIG'}";
  &loginfo;
  system("$sudobin -n -u loxberry cp -r -v $tempfolder/config/* $lbhomedir/config/plugins/$pfolder/ 2>&1");
  if ($? ne 0) {
    $message =  "$SL{'PLUGININSTALL.ERR_FILES'}";
    &logerr; 
    push(@errors,"CONFIG files: $message");
  } else {
    $message =  "$SL{'PLUGININSTALL.OK_FILES'}";
    &logok;
  }
  &setowner ("loxberry", "1", "$lbhomedir/config/plugins/$pfolder", "CONFIG files");

}

# Copy bin files
make_path("$lbhomedir/bin/plugins/$pfolder" , {chmod => 0755, owner=>'loxberry', group=>'loxberry'});
if (!&is_folder_empty("$tempfolder/bin")) {
  $message =  "$SL{'PLUGININSTALL.INF_BIN'}";
  &loginfo;
  system("$sudobin -n -u loxberry cp -r -v $tempfolder/bin/* $lbhomedir/bin/plugins/$pfolder/ 2>&1");
  if ($? ne 0) {
    $message =  "$SL{'PLUGININSTALL.ERR_FILES'}";
    &logerr; 
    push(@errors,"BIN files: $message");
  } else {
    $message =  "$SL{'PLUGININSTALL.OK_FILES'}";
    &logok;
  }

  &setrights ("755", "1", "$lbhomedir/bin/plugins/$pfolder", "BIN files");
  &setowner ("loxberry", "1", "$lbhomedir/bin/plugins/$pfolder", "BIN files");

}

# Copy Template files
make_path("$lbhomedir/templates/plugins/$pfolder" , {chmod => 0755, owner=>'loxberry', group=>'loxberry'});
if (!&is_folder_empty("$tempfolder/templates")) {
  $message =  "$SL{'PLUGININSTALL.INF_TEMPLATES'}";
  &loginfo;
  system("$sudobin -n -u loxberry cp -r -v $tempfolder/templates/* $lbhomedir/templates/plugins/$pfolder/ 2>&1");
  if ($? ne 0) {
    $message =  "$SL{'PLUGININSTALL.ERR_FILES'}";
    &logerr; 
    push(@errors,"TEMPLATE files: $message");
  } else {
    $message =  "$SL{'PLUGININSTALL.OK_FILES'}";
    &logok;
  }

  &setowner ("loxberry", "1", "$lbhomedir/templates/plugins/$pfolder", "TEMPLATE files");
  
}

# Copy Cron files
if (!&is_folder_empty("$tempfolder/cron")) {
  $message =  "$SL{'PLUGININSTALL.INF_CRONJOB'}";
  &loginfo;
  $openerr = 0;
  if (-e "$tempfolder/cron/crontab" && !-e "$lbhomedir/system/cron/cron.d/$pname") {
    system("cp -r -v $tempfolder/cron/crontab $lbhomedir/system/cron/cron.d/$pname 2>&1");
    if ($? ne 0) {
      $openerr = 1;
    }
  } 
  if (-e "$tempfolder/cron/cron.01min") {
    system("$sudobin -n -u loxberry cp -r -v $tempfolder/cron/cron.01min $lbhomedir/system/cron/cron.01min/$pname 2>&1");
    if ($? ne 0) {
      $openerr = 1;
    }
  } 
  if (-e "$tempfolder/cron/cron.03min") {
    system("$sudobin -n -u loxberry cp -r -v $tempfolder/cron/cron.03min $lbhomedir/system/cron/cron.03min/$pname 2>&1");
    if ($? ne 0) {
      $openerr = 1;
    }
  } 
  if (-e "$tempfolder/cron/cron.05min") {
    system("$sudobin -n -u loxberry cp -r -v $tempfolder/cron/cron.05min $lbhomedir/system/cron/cron.05min/$pname 2>&1");
    if ($? ne 0) {
      $openerr = 1;
    }
  } 
  if (-e "$tempfolder/cron/cron.10min") {
    system("$sudobin -n -u loxberry cp -r -v $tempfolder/cron/cron.10min $lbhomedir/system/cron/cron.10min/$pname 2>&1");
    if ($? ne 0) {
      $openerr = 1;
    }
  } 
  if (-e "$tempfolder/cron/cron.15min") {
    system("$sudobin -n -u loxberry cp -r -v $tempfolder/cron/cron.15min $lbhomedir/system/cron/cron.15min/$pname 2>&1");
    if ($? ne 0) {
      $openerr = 1;
    }
  } 
  if (-e "$tempfolder/cron/cron.30min") {
    system("$sudobin -n -u loxberry cp -r -v $tempfolder/cron/cron.30min $lbhomedir/system/cron/cron.30min/$pname 2>&1");
    if ($? ne 0) {
      $openerr = 1;
    }
  } 
  if (-e "$tempfolder/cron/cron.hourly") {
    system("$sudobin -n -u loxberry cp -r -v $tempfolder/cron/cron.hourly $lbhomedir/system/cron/cron.hourly/$pname 2>&1");
    if ($? ne 0) {
      $openerr = 1;
    }
  } 
  if (-e "$tempfolder/cron/cron.daily") {
    system("$sudobin -n -u loxberry cp -r -v $tempfolder/cron/cron.daily $lbhomedir/system/cron/cron.daily/$pname 2>&1");
    if ($? ne 0) {
      $openerr = 1;
    }
  } 
  if (-e "$tempfolder/cron/cron.weekly") {
    system("$sudobin -n -u loxberry cp -r -v $tempfolder/cron/cron.weekly01 $lbhomedir/system/cron/cron.weekly/$pname 2>&1");
    if ($? ne 0) {
      $openerr = 1;
    }
  } 
  if (-e "$tempfolder/cron/cron.monthly") {
    system("$sudobin -n -u loxberry cp -r -v $tempfolder/cron/cron.monthly $lbhomedir/system/cron/cron.monthly/$pname 2>&1");
    if ($? ne 0) {
      $openerr = 1;
    }
  } 
  if (-e "$tempfolder/cron/cron.yearly") {
    system("$sudobin -n -u loxberry cp -r -v $tempfolder/cron/cron.yearly $lbhomedir/system/cron/cron.yearly/$pname 2>&1");
    if ($? ne 0) {
      $openerr = 1;
    }
  } 
  if ($openerr) {
    $message =  "$SL{'PLUGININSTALL.ERR_FILES'}";
    &logerr; 
    push(@errors,"CRONJOB files: $message");
  } else {
    $message =  "$SL{'PLUGININSTALL.OK_FILES'}";
    &logok;
  }

  &setrights ("755", "1", "$lbhomedir/system/cron/cron.01min", "CRONJOB files");
  &setowner  ("loxberry", "1", "$lbhomedir/system/cron/cron.01min", "CRONJOB files");
  &setrights ("755", "1", "$lbhomedir/system/cron/cron.03min", "CRONJOB files");
  &setowner  ("loxberry", "1", "$lbhomedir/system/cron/cron.03min", "CRONJOB files");
  &setrights ("755", "1", "$lbhomedir/system/cron/cron.05min", "CRONJOB files");
  &setowner  ("loxberry", "1", "$lbhomedir/system/cron/cron.05min", "CRONJOB files");
  &setrights ("755", "1", "$lbhomedir/system/cron/cron.10min", "CRONJOB files");
  &setowner  ("loxberry", "1", "$lbhomedir/system/cron/cron.10min", "CRONJOB files");
  &setrights ("755", "1", "$lbhomedir/system/cron/cron.15min", "CRONJOB files");
  &setowner  ("loxberry", "1", "$lbhomedir/system/cron/cron.15min", "CRONJOB files");
  &setrights ("755", "1", "$lbhomedir/system/cron/cron.30min", "CRONJOB files");
  &setowner  ("loxberry", "1", "$lbhomedir/system/cron/cron.30min", "CRONJOB files");
  &setrights ("755", "1", "$lbhomedir/system/cron/cron.hourly", "CRONJOB files");
  &setowner  ("loxberry", "1", "$lbhomedir/system/cron/cron.hourly", "CRONJOB files");
  &setrights ("755", "1", "$lbhomedir/system/cron/cron.daily", "CRONJOB files");
  &setowner  ("loxberry", "1", "$lbhomedir/system/cron/cron.daily", "CRONJOB files");
  &setrights ("755", "1", "$lbhomedir/system/cron/cron.weekly", "CRONJOB files");
  &setowner  ("loxberry", "1", "$lbhomedir/system/cron/cron.weekly", "CRONJOB files");
  &setrights ("755", "1", "$lbhomedir/system/cron/cron.monthly", "CRONJOB files");
  &setowner  ("loxberry", "1", "$lbhomedir/system/cron/cron.monthly", "CRONJOB files");
  &setrights ("755", "1", "$lbhomedir/system/cron/cron.yearly", "CRONJOB files");
  &setowner  ("loxberry", "1", "$lbhomedir/system/cron/cron.yearly", "CRONJOB files");
  &setrights ("644", "0", "$lbhomedir/system/cron/cron.d/*", "CRONTAB files");
  &setowner  ("root", "0", "$lbhomedir/system/cron/cron.d/*", "CRONTAB files");

}

# Copy Data files
make_path("$lbhomedir/data/plugins/$pfolder" , {chmod => 0755, owner=>'loxberry', group=>'loxberry'});
if (!&is_folder_empty("$tempfolder/data")) {
  $message =  "$SL{'PLUGININSTALL.INF_DATAFILES'}";
  &loginfo;
  system("$sudobin -n -u loxberry cp -r -v $tempfolder/data/* $lbhomedir/data/plugins/$pfolder/ 2>&1");
  if ($? ne 0) {
    $message =  "$SL{'PLUGININSTALL.ERR_FILES'}";
    &logerr; 
    push(@errors,"DATA files: $message");
  } else {
    $message =  "$SL{'PLUGININSTALL.OK_FILES'}";
    &logok;
  }

  &setowner ("loxberry", "1", "$lbhomedir/data/plugins/$pfolder", "DATA files");

}

# Copy Log files
make_path("$lbhomedir/log/plugins/$pfolder" , {chmod => 0755, owner=>'loxberry', group=>'loxberry'});
if (!&is_folder_empty("$tempfolder/log")) {

  $message =  "$SL{'PLUGININSTALL.INF_LOGFILES'}";
  &loginfo;

  if ( $pinterface ne "1.0" ) {
    $message =  "*** DEPRECIATED *** This Plugin uses an outdated feature! Log files are stored in a RAMDISC now. The plugin has to create the logfiles at runtime! Please inform the PLUGIN Author at $pauthoremail";
    &logwarn; 
    push(@warnings,"LOG files: $message");
  }

  system("$sudobin -n -u loxberry cp -r -v $tempfolder/log/* $lbhomedir/log/plugins/$pfolder/ 2>&1");
  if ($? ne 0) {
    $message =  "$SL{'PLUGININSTALL.ERR_FILES'}";
    &logerr; 
    push(@errors,"LOG files: $message");
  } else {
    $message =  "$SL{'PLUGININSTALL.OK_FILES'}";
    &logok;
  }

  &setowner ("loxberry", "1", "$lbhomedir/log/plugins/$pfolder", "LOG files");

}

# Copy CGI files - DEPRECIATED!!!
if ( $pinterface eq "1.0" ) {
  make_path("$lbhomedir/webfrontend/htmlauth/plugins/$pfolder" , {chmod => 0755, owner=>'loxberry', group=>'loxberry'});
  if (!&is_folder_empty("$tempfolder/webfrontend/cgi")) {
    $message =  "$SL{'PLUGININSTALL.INF_HTMLAUTHFILES'}";
    &loginfo;
    system("$sudobin -n -u loxberry cp -r -v $tempfolder/webfrontend/cgi/* $lbhomedir/webfrontend/htmlauth/plugins/$pfolder/ 2>&1");
    if ($? ne 0) {
      $message =  "$SL{'PLUGININSTALL.ERR_FILES'}";
      &logerr; 
      push(@errors,"HTMLAUTH files: $message");
    } else {
      $message =  "$SL{'PLUGININSTALL.OK_FILES'}";
      &logok;
    }

    &setowner ("loxberry", "1", "$lbhomedir/webfrontend/htmlauth/plugins/$pfolder", "HTMLAUTH files");
    &setrights ("755", "1", "$lbhomedir/webfrontend/htmlauth/plugins/$pfolder", "HTMLAUTH files");

  }
}

# Copy HTMLAUTH files
if ( $pinterface ne "1.0" ) {
  make_path("$lbhomedir/webfrontend/htmlauth/plugins/$pfolder" , {chmod => 0755, owner=>'loxberry', group=>'loxberry'});
  if (!&is_folder_empty("$tempfolder/webfrontend/htmlauth")) {
    $message =  "$SL{'PLUGININSTALL.INF_HTMLAUTHFILES'}";
    &loginfo;
    system("$sudobin -n -u loxberry cp -r -v $tempfolder/webfrontend/htmlauth/* $lbhomedir/webfrontend/htmlauth/plugins/$pfolder/ 2>&1");
    if ($? ne 0) {
      $message =  "$SL{'PLUGININSTALL.ERR_FILES'}";
      &logerr; 
      push(@errors,"HTMLAUTH files: $message");
    } else {
      $message =  "$SL{'PLUGININSTALL.OK_FILES'}";
      &logok;
    }

    &setrights ("755", "0", "$lbhomedir/webfrontend/htmlauth/plugins/$pfolder", "HTMLAUTH files", ".*\\.cgi\\|.*\\.pl\\|.*\\.sh");
    &setowner ("loxberry", "1", "$lbhomedir/webfrontend/htmlauth/plugins/$pfolder", "HTMLAUTH files");

  }
}

# Copy HTML files
make_path("$lbhomedir/webfrontend/html/plugins/$pfolder" , {chmod => 0755, owner=>'loxberry', group=>'loxberry'});
if (!&is_folder_empty("$tempfolder/webfrontend/html")) {
  $message =  "$SL{'PLUGININSTALL.INF_HTMLFILES'}";
  &loginfo;
  system("$sudobin -n -u loxberry cp -r -v $tempfolder/webfrontend/html/* $lbhomedir/webfrontend/html/plugins/$pfolder/ 2>&1");
  if ($? ne 0) {
    $message =  "$SL{'PLUGININSTALL.ERR_FILES'}";
    &logerr; 
    push(@errors,"HTML files: $message");
  } else {
    $message =  "$SL{'PLUGININSTALL.OK_FILES'}";
    &logok;
  }

    &setrights ("755", "0", "$lbhomedir/webfrontend/html/plugins/$pfolder", "HTML files", ".*\\.cgi\\|.*\\.pl\\|.*\\.sh");
    &setowner ("loxberry", "1", "$lbhomedir/webfrontend/html/plugins/$pfolder", "HTML files");

}

# Copy Icon files
make_path("$lbhomedir/webfrontend/html/system/images/icons/$pfolder" , {chmod => 0755, owner=>'loxberry', group=>'loxberry'});
$message =  "$SL{'PLUGININSTALL.INF_ICONFILES'}";
&loginfo;
system("$sudobin -n -u loxberry cp -r -v $tempfolder/icons/* $lbhomedir/webfrontend/html/system/images/icons/$pfolder/ 2>&1");
if ($? ne 0) {
  system("$sudobin -n -u loxberry cp -r -v $lbhomedir/webfrontend/html/system/images/icons/default/* $lbhomedir/webfrontend/html/system/images/icons/$pfolder/ 2>&1");
  $message =  "$SL{'PLUGININSTALL.ERR_ICONFILES'}";
  &logerr; 
  push(@errors,"ICON files: $message");
} else {
  $openerr = 0;
  if (!-e "$lbhomedir/webfrontend/html/system/images/icons/$pfolder/icon_64.png") {
    $openerr = 1;
    system("$sudobin -n -u loxberry cp -r -v $lbhomedir/webfrontend/html/system/images/icons/default/icon_64.png $lbhomedir/webfrontend/html/system/images/icons/$pfolder/ 2>&1");
  } 
  if (!-e "$lbhomedir/webfrontend/html/system/images/icons/$pfolder/icon_128.png") {
    $openerr = 1;
    system("$sudobin -n -u loxberry cp -r -v $lbhomedir/webfrontend/html/system/images/icons/default/icon_128.png $lbhomedir/webfrontend/html/system/images/icons/$pfolder/ 2>&1");
  } 
  if (!-e "$lbhomedir/webfrontend/html/system/images/icons/$pfolder/icon_256.png") {
    $openerr = 1;
    system("$sudobin -n -u loxberry cp -r -v $lbhomedir/webfrontend/html/system/images/icons/default/icon_256.png $lbhomedir/webfrontend/html/system/images/icons/$pfolder/ 2>&1");
  } 
  if (!-e "$lbhomedir/webfrontend/html/system/images/icons/$pfolder/icon_512.png") {
    $openerr = 1;
    system("$sudobin -n -u loxberry cp -r -v $lbhomedir/webfrontend/html/system/images/icons/default/icon_512.png $lbhomedir/webfrontend/html/system/images/icons/$pfolder/ 2>&1");
  } 
  if ($openerr) {
    $message =  "$SL{'PLUGININSTALL.ERR_ICONFILES'}";
    &logerr;
    push(@errors,"ICON files: $message");
  } else { 
    $message =  "$SL{'PLUGININSTALL.OK_ICONFILES'}";
    &logok;
  }

  &setowner ("loxberry", "1", "$lbhomedir/webfrontend/html/system/images/icons/$pfolder", "ICON files");

}

# Copy Daemon file
if (-f "$tempfolder/daemon/daemon") {
  $message =  "$SL{'PLUGININSTALL.INF_DAEMON'}";
  &loginfo;
  system("cp -v $tempfolder/daemon/daemon $lbhomedir/system/daemons/plugins/$pname 2>&1");
  if ($? ne 0) {
    $message =  "$SL{'PLUGININSTALL.ERR_FILES'}";
    &logerr; 
    push(@errors,"DAEMON FILE: $message");
  } else {
    $message =  "$SL{'PLUGININSTALL.OK_FILES'}";
    &logok;
  }

  if ( $pinterface eq "1.0" ) {
		setrights ("777", "1", "$lbhomedir/system/daemons/plugins", "Plugin interface V1.0 DAEMON script");
 }
	
  &setrights ("755", "0", "$lbhomedir/system/daemons/plugins/$pname", "DAEMON script");
  &setowner ("root", "0", "$lbhomedir/system/daemons/plugins/$pname", "DAEMON script");

}

# Copy Uninstall file
if (-f "$tempfolder/uninstall/uninstall") {
  $message =  "$SL{'PLUGININSTALL.INF_UNINSTALL'}";
  &loginfo;
  system("cp -r -v $tempfolder/uninstall/uninstall $lbhomedir/data/system/uninstall/$pname 2>&1");
  if ($? ne 0) {
    $message =  "$SL{'PLUGININSTALL.ERR_FILES'}";
    &logerr; 
    push(@errors,"UNINSTALL Script: $message");
  } else {
    $message =  "$SL{'PLUGININSTALL.OK_FILES'}";
    &logok;
  }

  &setrights ("755", "0", "$lbhomedir/data/system/uninstall/$pname", "UNINSTALL script");
  &setowner ("root", "0", "$lbhomedir/data/system/uninstall/$pname", "UNINSTALL script");

}

# Copy Sudoers file
if (-f "$tempfolder/sudoers/sudoers") {
  $message =  "$SL{'PLUGININSTALL.INF_SUDOERS'}";
  &loginfo;
  system("cp -v $tempfolder/sudoers/sudoers $lbhomedir/system/sudoers/$pname 2>&1");
  if ($? ne 0) {
    $message =  "$SL{'PLUGININSTALL.ERR_FILES'}";
    &logerr; 
    push(@errors,"SUDOERS file: $message");
  } else {
    $message =  "$SL{'PLUGININSTALL.OK_FILES'}";
    &logok;
  }

  &setrights ("644", "0", "$lbhomedir/system/sudoers/$pname", "SUDOERS file");
  &setowner ("root", "0", "$lbhomedir/system/sudoers/$pname", "SUDOERS file");

}

# Installing additional packages
if ( $pinterface eq "1.0" ) {
	our $aptfile="$tempfolder/apt";
} else {
	our $aptfile="$tempfolder/dpkg/apt";
}

if (-e "$aptfile") {

  if (-e "$lbhomedir/data/system/lastaptupdate.dat") {
    open(F,"<$lbhomedir/data/system/lastaptupdate.dat");
      $lastaptupdate = <F>;
    close(F);
  } else {
    $lastaptupdate = 0;
  }
  $now = time;
  # If last run of apt-get update is longer than 24h ago, do a refresh.
  if ($now > $lastaptupdate+86400) {
    $message =  "$SL{'PLUGININSTALL.INF_APTREFRESH'}";
    &loginfo;
    $message = "Command: $dpkgbin --configure -a";
    &loginfo;
    system("$dpkgbin --configure -a 2>&1");
    $message = "Command: $aptbin -q -y update";
    &loginfo;
    system("$aptbin -q -y update 2>&1");
    if ($? ne 0) {
      $message =  "$SL{'PLUGININSTALL.ERR_APTREFRESH'}";
      &logerr; 
      push(@errors,"APT refresh: $message");
    } else {
      $message =  "$SL{'PLUGININSTALL.OK_APTREFRESH'}";
      &logok;
      open(F,">$lbhomedir/data/system/lastaptupdate.dat");
	flock(F,2);
        print F $now;
	flock(F,8);
      close(F);
    }
  }
  $message =  "$SL{'PLUGININSTALL.INF_APT'}";
  &loginfo;
  $openerr = 0;
  open(F,"<$aptfile") or ($openerr = 1);
    if ($openerr) {
      $message =  "$SL{'PLUGININSTALL.ERR_APT'}";
      &logerr;
      push(@errors,"APT install: $message");
    }
  @data = <F>;
  foreach (@data){
    s/[\n\r]//g;
    # Comments
    if ($_ =~ /^\s*#.*/) {
      next;
    }
    $aptpackages = $aptpackages . " " . $_;
  }
  close (F);

  $message = "Command: $dpkgbin --configure -a";
  &loginfo;
  system("$dpkgbin --configure -a 2>&1");
  $message = "Command: $aptbin --no-install-recommends -q -y install $aptpackages";
  &loginfo;
  system("$aptbin --no-install-recommends -q -y install $aptpackages 2>&1");
  if ($? ne 0) {
    $message =  "$SL{'PLUGININSTALL.ERR_PACKAGESINSTALL'}";
    &logwarn; 
    push(@warnings,"APT install: $message");
    # If it failed, maybe due to an outdated apt-database... So
    # do a apt-get update once more
    $message = "Command: $dpkgbin --configure -a";
    &loginfo;
    system("$dpkgbin --configure -a 2>&1");
    $message =  "$SL{'PLUGININSTALL.INF_APTREFRESH'}";
    &loginfo;
    $message = "Command: $aptbin -q -y update";
    &loginfo;
    system("$aptbin -q -y update 2>&1");
    if ($? ne 0) {
      $message =  "$SL{'PLUGININSTALL.ERR_APTREFRESH'}";
      &logerr; 
      push(@errors,"APT refresh: $message");
    } else {
      $message =  "$SL{'PLUGININSTALL.OK_APTREFRESH'}";
      &logok;
      open(F,">$lbhomedir/data/system/lastaptupdate.dat");
	flock(F,2);
        print F $now;
	flock(F,8);
      close(F);
    }
    # And try to install packages again...
    $message = "Command: $dpkgbin --configure -a";
    &loginfo;
    system("$dpkgbin --configure -a 2>&1");
    $message = "Command: $aptbin --no-install-recommends -q -y install $aptpackages";
    &loginfo;
    system("$aptbin --no-install-recommends -q -y install $aptpackages 2>&1");
    if ($? ne 0) {
      $message =  "$SL{'PLUGININSTALL.ERR_PACKAGESINSTALL'}";
      &logerr; 
      push(@errors,"APT install: $message");
    } else {
      $message =  "$SL{'PLUGININSTALL.OK_PACKAGESINSTALL'}";
      &logok;
    }
  } else {
    $message =  "$SL{'PLUGININSTALL.OK_PACKAGESINSTALL'}";
    &logok;
  }

}

if ( $pinterface ne "1.0" ) {
	my $thisarch;
	if (-e "$lbsconfigdir/is_raspberry.cfg") {
		$thisarch = "raspberry";
	}
	elsif (-e "$lbsconfigdir/is_x86.cfg") {
		$thisarch = "x86";
	}
	elsif (-e "$lbsconfigdir/is_x64.cfg") {
		$thisarch = "x64";
	}
	if ( $thisarch ) {
		my @debfiles = glob("$tempfolder/dpkg/$thisarch/*.deb");
		if( my $cnt = @debfiles ){
			$message = "Command: $dpkgbin -i -R $tempfolder/dpkg/$thisarch";
			&loginfo;
			system("$dpkgbin -i -R $tempfolder/dpkg/$thisarch 2>&1");
			if ($? ne 0) {
				$message =  "$SL{'PLUGININSTALL.ERR_PACKAGESINSTALL'}";
				&logerr; 
				push(@errors,"APT install: $message");
			} else {
				$message =  "$SL{'PLUGININSTALL.OK_PACKAGESINSTALL'}";
				&logok;
			}
		}
	}
}

# We have to recreate the skels for system log folders in tmpfs
$message =  "$SL{'PLUGININSTALL.INF_LOGSKELS'}";
&loginfo;
$message = "Command: $lbssbindir/createskelfolders.pl";
system("$lbssbindir/createskelfolders.pl 2>&1");
$exitcode  = $? >> 8;
if ($exitcode eq 1) {
  $message =  "$SL{'PLUGININSTALL.ERR_SCRIPT'}";
  &logerr; 
  push(@errors,"SKEL FOLDERS: $message");
} 
else {
  $message =  "$SL{'PLUGININSTALL.OK_SCRIPT'}";
  &logok;
}

# Executing postinstall script
if (-f "$tempfolder/postinstall.sh") {
  $message =  "$SL{'PLUGININSTALL.INF_START_POSTINSTALL'}";
  &loginfo;

  $message = "Command: cd \"$tempfolder\" && $sudobin -n -u loxberry \"$tempfolder/postinstall.sh\" \"$tempfile\" \"$pname\" \"$pfolder\" \"$pversion\" \"$lbhomedir\" \"$tempfolder\"";
  &loginfo;

  system("$sudobin -n -u loxberry $chmodbin -v a+x \"$tempfolder/postinstall.sh\" 2>&1");
  system("cd \"$tempfolder\" && $sudobin -n -u loxberry \"$tempfolder/postinstall.sh\" \"$tempfile\" \"$pname\" \"$pfolder\" \"$pversion\" \"$lbhomedir\" \"$tempfolder\" 2>&1");
  $exitcode  = $? >> 8;
  if ($exitcode eq 1) {
    $message =  "$SL{'PLUGININSTALL.ERR_SCRIPT'}";
    &logerr; 
    push(@errors,"POSTINSTALL: $message");
  } 
  elsif ($exitcode > 1) {
    $message =  "$SL{'PLUGININSTALL.FAIL_SCRIPT'}";
    &logfail; 
  }
  else {
    $message =  "$SL{'PLUGININSTALL.OK_SCRIPT'}";
    &logok;
  }

}

# Executing postupgrade script
if ($isupgrade) {
  if (-f "$tempfolder/postupgrade.sh") {
    $message =  "$SL{'PLUGININSTALL.INF_START_POSTUPGRADE'}";
    &loginfo;

    $message = "Command: cd \"$tempfolder\" && $sudobin -n -u loxberry \"$tempfolder/postupgrade.sh\" \"$tempfile\" \"$pname\" \"$pfolder\" \"$pversion\" \"$lbhomedir\" \"$tempfolder\"";
    &loginfo;

    system("$sudobin -n -u loxberry $chmodbin -v a+x \"$tempfolder/postupgrade.sh\" 2>&1");
    system("cd \"$tempfolder\" && $sudobin -n -u loxberry \"$tempfolder/postupgrade.sh\" \"$tempfile\" \"$pname\" \"$pfolder\" \"$pversion\" \"$lbhomedir\" \"$tempfolder\" 2>&1");
    $exitcode  = $? >> 8;
    if ($exitcode eq 1) {
      $message =  "$SL{'PLUGININSTALL.ERR_SCRIPT'}";
      &logerr; 
      push(@errors,"POSTUPGRADE: $message");
    } 
    elsif ($exitcode > 1) {
      $message =  "$SL{'PLUGININSTALL.FAIL_SCRIPT'}";
      &logfail; 
    }
    else {
      $message =  "$SL{'PLUGININSTALL.OK_SCRIPT'}";
      &logok;
    }

  }
}

# Executing postroot script
if (-f "$tempfolder/postroot.sh") {
  $message =  "$SL{'PLUGININSTALL.INF_START_POSTROOT'}";
  &loginfo;

  $message = "Command: cd \"$tempfolder\" && \"$tempfolder/postroot.sh\" \"$tempfile\" \"$pname\" \"$pfolder\" \"$pversion\" \"$lbhomedir\" \"$tempfolder\"";
  &loginfo;

  system("$sudobin -n -u loxberry $chmodbin -v a+x \"$tempfolder/postroot.sh\" 2>&1");
  system("cd \"$tempfolder\" && \"$tempfolder/postroot.sh\" \"$tempfile\" \"$pname\" \"$pfolder\" \"$pversion\" \"$lbhomedir\" \"$tempfolder\" 2>&1");
  $exitcode  = $? >> 8;
  if ($exitcode eq 1) {
    $message =  "$SL{'PLUGININSTALL.ERR_SCRIPT'}";
    &logerr; 
    push(@errors,"POSTROOT: $message");
  } 
  elsif ($exitcode > 1) {
    $message =  "$SL{'PLUGININSTALL.FAIL_SCRIPT'}";
    &logfail; 
  }
  else {
    $message =  "$SL{'PLUGININSTALL.OK_SCRIPT'}";
    &logok;
  }

}

# Copy installation files
make_path("$lbhomedir/data/system/install/$pfolder" , {chmod => 0755, owner=>'loxberry', group=>'loxberry'});
my @installfiles = glob("$tempfolder/*.sh");
if( my $cnt = @installfiles ){
	$message =  "$SL{'PLUGININSTALL.INF_INSTALLSCRIPTS'}";
	&loginfo;
	system("$sudobin -n -u loxberry cp -v $tempfolder/*.sh $lbhomedir/data/system/install/$pfolder 2>&1");
	if ($? ne 0) {
	  $message =  "$SL{'PLUGININSTALL.ERR_FILES'}";
	  &logerr; 
	  push(@errors,"INSTALL scripts: $message");
	} else {
	  $message =  "$SL{'PLUGININSTALL.OK_FILES'}";
	  &logok;
	}
	&setowner ("loxberry", "1", "$lbhomedir/data/system/install/$pfolder", "INSTALL scripts");
	&setrights ("755", "1", "$lbhomedir/data/system/install/$pfolder", "INSTALL scripts");
}
if( -e "$tempfolder/apt" ){
	$message =  "$SL{'PLUGININSTALL.INF_INSTALLAPT'}";
	&loginfo;
	system("$sudobin -n -u loxberry cp -rv $tempfolder/apt $lbhomedir/data/system/install/$pfolder 2>&1");
	if ($? ne 0) {
	  $message =  "$SL{'PLUGININSTALL.ERR_FILES'}";
	  &logerr; 
	  push(@errors,"INSTALL scripts: $message");
	} else {
	  $message =  "$SL{'PLUGININSTALL.OK_FILES'}";
	  &logok;
	}
	&setowner ("loxberry", "1", "$lbhomedir/data/system/install/$pfolder", "INSTALL scripts");
	&setrights ("755", "1", "$lbhomedir/data/system/install/$pfolder", "INSTALL scripts");
}
if( -e "$tempfolder/dpkg" ){
	$message =  "$SL{'PLUGININSTALL.INF_INSTALLAPT'}";
	&loginfo;
	system("$sudobin -n -u loxberry cp -rv $tempfolder/dpkg $lbhomedir/data/system/install/$pfolder 2>&1");
	if ($? ne 0) {
	  $message =  "$SL{'PLUGININSTALL.ERR_FILES'}";
	  &logerr; 
	  push(@errors,"INSTALL scripts: $message");
	} else {
	  $message =  "$SL{'PLUGININSTALL.OK_FILES'}";
	  &logok;
	}
	&setowner ("loxberry", "1", "$lbhomedir/data/system/install/$pfolder", "INSTALL scripts");
	&setrights ("755", "1", "$lbhomedir/data/system/install/$pfolder", "INSTALL scripts");
}

# Set permissions
#$message =  "$SL{'PLUGININSTALL.INF_PERMISSIONS'}";
#&loginfo;
#system("$lbssbindir/resetpermissions.sh 2>&1");

# Cleaning
$message =  "$SL{'PLUGININSTALL.INF_END'}";
&loginfo;
print "Tempfolder is: $tempfile\n";
if ( -e "/tmp/uploads/$tempffile" ) {
	system("$sudobin -n -u loxberry rm -vrf /tmp/uploads/$tempfile 2>&1");
}
if ( $R::tempfile ) {
	system("$sudobin -n -u loxberry rm -vf /tmp/$tempfile.zip 2>&1");
} 

# Finished
$message =  "$SL{'PLUGININSTALL.OK_END'}";
&logok;

# Check for a reboot for older plugins (V1)
#system ("cat /tmp/$tempfile.log | grep -E -iq 'reboot|restart|neustart|neu starten' 2>&1");
#if ($? eq 0) {
#	$preboot = 1;
#}

# Set Status
if (-e $statusfile) {
  if ($preboot) {
    open (F, ">$statusfile");
    flock(F,2);
      print F "3";
    flock(F,8);
    close (F);
    reboot_required("$SL{'PLUGININSTALL.INF_REBOOT'} $ptitle");
  } else {
    open (F, ">$statusfile");
    flock(F,2);
      print F "0";
    flock(F,8);
    close (F);
  }
}

# Log errora
if (@errors || @warnings) {
	LOGWARN "An error or warning occurred";
} else {
	LOGOK "Everything seems to be OK";
}
LOGEND;

# Saving Logfile
$message =  "$SL{'PLUGININSTALL.INF_SAVELOG'}";
&loginfo;
system("cp -v /tmp/$tempfile.log $lbhomedir/log/system/plugininstall/$pname.log 2>&1");
&setowner ("loxberry", "0", "$lbhomedir/log/system/plugininstall/$pname.log", "LOG Save");

$message =  "$SL{'PLUGININSTALL.INF_LAST'}";
&loginfo;

print "\n\n";

# Error summarize
if (@errors || @warnings) {
  $message = "==================================================================================";
  &loginfo;
  $message =  "$SL{'PLUGININSTALL.INF_ERRORSUMMARIZE'}";
  &loginfo;
  $message = "==================================================================================";
  &loginfo;
  foreach(@errors) {
    $message = $_;
    &logerr;
  }
  foreach(@warnings) {
    $message = $_;
    &logwarn;
  }
}
if ($chkhcpath) {
  print "$chkhcpath";
}

# Remove Lock
LoxBerry::System::unlock( lockfile => 'plugininstall' );

exit (0);

}

#####################################################
# 
# Subroutines
#
#####################################################

#####################################################
# Purge installation
#####################################################

sub purge_installation {

  my $option = shift; # http://wiki.selfhtml.org/wiki/Perl/Subroutinen

  if ($pfolder) {
    # Plugin Folders
    system("$sudobin -n -u loxberry rm -rfv $lbhomedir/config/plugins/$pfolder/ 2>&1");
    system("$sudobin -n -u loxberry rm -rfv $lbhomedir/bin/plugins/$pfolder/ 2>&1");
    system("$sudobin -n -u loxberry rm -rfv $lbhomedir/data/plugins/$pfolder/ 2>&1");
    system("$sudobin -n -u loxberry rm -rfv $lbhomedir/templates/plugins/$pfolder/ 2>&1");
    system("$sudobin -n -u loxberry rm -rfv $lbhomedir/webfrontend/htmlauth/plugins/$pfolder/ 2>&1");
    system("$sudobin -n -u loxberry rm -rfv $lbhomedir/webfrontend/html/plugins/$pfolder/ 2>&1");
    system("$sudobin -n -u loxberry rm -rfv $lbhomedir/data/system/install/$pfolder 2>&1");
    # Icons for Main Menu
    system("$sudobin -n -u loxberry rm -rfv $lbhomedir/webfrontend/html/system/images/icons/$pfolder/ 2>&1");
  }

  if ($pname) {
    # Daemon file
    system("rm -fv $lbhomedir/system/daemons/plugins/$pname 2>&1");
    # Uninstall file
    if ($option ne "all") {
      system("rm -fv $lbhomedir/data/system/uninstall/$pname 2>&1");
    }
    # Cron jobs
    system("$sudobin -n -u loxberry rm -fv $lbhomedir/system/cron/cron.01min/$pname 2>&1");
    system("$sudobin -n -u loxberry rm -fv $lbhomedir/system/cron/cron.03min/$pname 2>&1");
    system("$sudobin -n -u loxberry rm -fv $lbhomedir/system/cron/cron.05min/$pname 2>&1");
    system("$sudobin -n -u loxberry rm -fv $lbhomedir/system/cron/cron.10min/$pname 2>&1");
    system("$sudobin -n -u loxberry rm -fv $lbhomedir/system/cron/cron.15min/$pname 2>&1");
    system("$sudobin -n -u loxberry rm -fv $lbhomedir/system/cron/cron.30min/$pname 2>&1");
    system("$sudobin -n -u loxberry rm -fv $lbhomedir/system/cron/cron.hourly/$pname 2>&1");
    system("$sudobin -n -u loxberry rm -fv $lbhomedir/system/cron/cron.daily/$pname 2>&1");
    system("$sudobin -n -u loxberry rm -fv $lbhomedir/system/cron/cron.weekly/$pname 2>&1");
    system("$sudobin -n -u loxberry rm -fv $lbhomedir/system/cron/cron.monthly/$pname 2>&1");
    system("$sudobin -n -u loxberry rm -fv $lbhomedir/system/cron/cron.yearly/$pname 2>&1");
    # Sudoers
    system("rm -fv $lbhomedir/system/sudoers/$pname 2>&1");
    # Install Log
    system("rm -fv $lbhomedir/log/system/plugininstall/$pname.log 2>&1");
  }

  # This will only be purged if we do an uninstallation
  if ($option eq "all") {

  # Clean Database
  if ($pid) {
    open(F,"+<$lbsdatadir/plugindatabase.dat") or ($openerr = 1);
      if ($openerr) {
        $message =  "$SL{'PLUGININSTALL.ERR_DATABASE'}";
        &logerr;
      }
      flock(F,2);
        @data = <F>;
        seek(F,0,0);
        truncate(F,0);
        foreach (@data){
          s/[\n\r]//g;
          # Comments
          if ($_ =~ /^\s*#.*/) {
            print F "$_\n";
            next;
          }
          @fields = split(/\|/);
          if (@fields[0] eq $pid) {
            next;
          } else {
            print F "$_\n";
          }
        }
      flock(F,8);
      close (F);
    }

    if ($pfolder) {
      # Log
      system("$sudobin -n -u loxberry rm -rfv $lbhomedir/log/plugins/$pfolder/ 2>&1");
    }

    if ($pname) {
      # Executing uninstall script
      if (-f "$lbhomedir/data/system/uninstall/$pname") {
        $message =  "$SL{'PLUGININSTALL.INF_START_UNINSTALL_EXE'}";
        &loginfo;

        system("\"$lbhomedir/data/system/uninstall/$pname\" 2>&1");
  	my $exitcode  = $? >> 8;
        if ($exitcode eq 1) {
          $message =  "$SL{'PLUGININSTALL.ERR_SCRIPT'}";
          &logerr; 
          push(@errors,"UNINSTALL execution: $message");
        } 
        elsif ($exitcode > 1) {
          $message =  "$SL{'PLUGININSTALL.FAIL_SCRIPT'}";
          &logfail; 
        }
        else {
          $message =  "$SL{'PLUGININSTALL.OK_SCRIPT'}";
          &logok;
        }
      }
      system("rm -fv $lbhomedir/data/system/uninstall/$pname 2>&1");

      # Crontab
      system("rm -vf $lbhomedir/system/cron/cron.d/$pname 2>&1");
    }
  }

return();

}

#####################################################
# Logging installation
#####################################################

sub logerr {

	my $currtime = currtime(hr);
	if ( !$is_cgi ) {
		print "$currtime \e[1m\e[31mERROR:\e[0m $message\n";
  		open (LOG, ">>$logfile");
		flock(LOG,2);
    		print LOG "$currtime <ERROR> $message\n";
		flock(LOG,8);
  		close (LOG);
	} else {
    		print "$currtime <ERROR> $message\n";
	}
	
	# Notify
	notify ( "plugininstall", "$pname", $SL{'PLUGININSTALL.UI_NOTIFY_INSTALL_ERROR'} . " " . $ptitle . ": " . $message);

	return();

}

sub logfail {

	my $currtime = currtime(hr);
	if ( !$is_cgi ) {
		print "$currtime \e[1m\e[31mFAIL:\e[0m $message\n";
  		open (LOG, ">>$logfile");
		flock(LOG,2);
    		print LOG "$currtime <FAIL> $message\n";
		flock(LOG,8);
  		close (LOG);
	} else {
    		print "$currtime <FAIL> $message\n";
	}

	if ( -e "/tmp/uploads/$tempffile" ) {
	      system("$sudobin -n -u loxberry rm -rf /tmp/uploads/$tempfile 2>&1");
	}
	if ( $R::tempfile ) {
		system("$sudobin -n -u loxberry rm -vf /tmp/$tempfile.zip 2>&1");
	} 

	if (-e $statusfile) {
	  open (F, ">$statusfile");
	  flock(F,2);
	    print F "2";
	  flock(F,8);
	  close (F);
	}
	
	# Notify
	$message = $message . " " . $SL{'PLUGININSTALL.UI_INSTALL_LABEL_ERROR'};
	notify ( "plugininstall", "$pname", $SL{'PLUGININSTALL.UI_NOTIFY_INSTALL_FAIL'} . " " . $ptitle . ": " . $message, 1);

	# Unlock and exit
	LoxBerry::System::unlock( lockfile => 'plugininstall' );
	exit (1);

}

sub logwarn {

	my $currtime = currtime(hr);
	if ( !$is_cgi ) {
		print "$currtime \e[1m\e[31mWARNING:\e[0m $message\n";
  		open (LOG, ">>$logfile");
		flock(LOG,2);
    		print LOG "$currtime <WARNING> $message\n";
		flock(LOG,8);
  		close (LOG);
	} else {
    		print "$currtime <WARNING> $message\n";
	}
	
	# Notify
	notify ( "plugininstall", "$pname", $SL{'PLUGININSTALL.UI_NOTIFY_INSTALL_WARN'} . " " . $ptitle . ": " . $message);

	return();

}


sub loginfo {

	my $currtime = currtime(hr);
	if ( !$is_cgi ) {
		print "$currtime \e[1mINFO:\e[0m $message\n";
  		open (LOG, ">>$logfile");
		flock(LOG,2);
    		print LOG "$currtime <INFO> $message\n";
		flock(LOG,8);
  		close (LOG);
	} else {
    		print "$currtime <INFO> $message\n";
	}

	return();

}

sub logok {

	my $currtime = currtime(hr);
	if ( !$is_cgi ) {
		print "$currtime \e[1m\e[32mOK:\e[0m $message\n";
  		open (LOG, ">>$logfile");
		flock(LOG,2);
    		print LOG "$currtime <OK> $message\n";
		flock(LOG,8);
  		close (LOG);
	} else {
    		print "$currtime <OK> $message\n";
	}

	return();

}

#####################################################
# Random
#####################################################

sub generate {
        local($e) = @_;
        my($zufall,@words,$more);

        if($e =~ /^\d+$/){
                $more = $e;
        }else{
                $more = "10";
        }

        @words = qw(A B C D E F G H I J K L M N O P Q R S T U V W X Y Z a b c d e f g h i j k l m n o p q r s t u v w x y z 0 1 2 3 4 5 6 7 8 9);

        foreach (1..$more){
                $zufall .= $words[int rand($#words+1)];
        }

        return($zufall);
}

#####################################################
# Check if folder is empty
#####################################################

sub is_folder_empty {
  my $dirname = shift;
  opendir(my $dh, $dirname); 
  return scalar(grep { $_ ne "." && $_ ne ".." } readdir($dh)) == 0;
}

#####################################################
# Set owner
#####################################################

# &setowner ("loxberry", "1", "path/to/folder", "CONFIG files");
# &setowner ("root", "0", "path/to/file", "DAEMON script");

sub setowner {

  my $owner = shift;
  my $group = $owner;
  my $recursive = shift;
  my $target = shift;
  my $type = shift;

  if ( $recursive ) {
    our $chownoptions = "-Rv";
  } else {
    our $chownoptions = "-v";
  }

  $message = $SL{'PLUGININSTALL.INF_FILE_OWNER'} . " $chownbin $chownoptions $owner.$group $target";
  &loginfo;
  system("$chownbin $chownoptions $owner.$group $target 2>&1");
  if ($? ne 0) {
    $message =  "$SL{'PLUGININSTALL.ERR_FILE_OWNER'}";
    &logerr; 
    push(@errors,"$type: $message");
  } else {
    $message =  "$SL{'PLUGININSTALL.OK_FILE_OWNER'}";
    &logok;
  }

}

#####################################################
# Set permissions
#####################################################

# &setrights ("755", "1", "path/to/folder", "CONFIG files" [,"Regex"]);
# &setrights ("644", "0", "path/to/file", "DAEMON script" [,"Regex"]);

sub setrights {

  my $rights = shift;
  my $recursive = shift;
  my $target = shift;
  my $type = shift;
  my $regex = shift;

  if ( $recursive ) {
    our $chmodoptions = "-Rv";
  } else {
    our $chmodoptions = "-v";
  }

  if ($regex) {

    $chmodoptions = "-v";
    $message = $SL{'PLUGININSTALL.INF_FILE_PERMISSIONS'} . " $findbin $target -iregex '$regex' -exec $chmodbin $chmodoptions $rights {} \\;";
    &loginfo;
    system("$sudobin -n -u loxberry $findbin $target -iregex '$regex' -exec $chmodbin $chmodoptions $rights {} \\; 2>&1");

  } else {

    $message = $SL{'PLUGININSTALL.INF_FILE_PERMISSIONS'} . " $chmodbin $chmodoptions $rights $target";
    &loginfo;
    system("$chmodbin $chmodoptions $rights $target 2>&1");

  }
  if ($? ne 0) {
    $message =  "$SL{'PLUGININSTALL.ERR_FILE_PERMISSIONS'}";
    &logerr; 
    push(@errors,"$type: $message");
  } else {
    $message =  "$SL{'PLUGININSTALL.OK_FILE_PERMISSIONS'}";
    &logok;
  }

}

#####################################################
# Replace strings in pluginfiles
#####################################################

# &replaceenv ("loxberry", "1", "path/to/folder");

sub replaceenv {

  my $user = shift;
  my $recursive = shift;
  my $target = shift;

  # Folder
  if ($recursive) {

    $message =  $SL{'PLUGININSTALL.INF_REPLACEING'} . " REPLACELBHOMEDIR in $target";
    &loginfo;
    system("$sudobin -n -u $user $findbin $target -type f -iregex '.*' -exec /bin/sed -i 's#REPLACELBHOMEDIR#$lbhomedir#g' {} \\; 2>&1");
    $message =  $SL{'PLUGININSTALL.INF_REPLACEING'} . " REPLACELBPPLUGINDIR in $target";
    &loginfo;
    system("$sudobin -n -u $user $findbin $target -type f -iregex '.*' -exec /bin/sed -i 's#REPLACELBPPLUGINDIR#$pfolder#g' {} \\; 2>&1");
    $message =  $SL{'PLUGININSTALL.INF_REPLACEING'} . " REPLACELBPHTMLAUTHDIR in $target";
    &loginfo;
    system("$sudobin -n -u $user $findbin $target -type f -iregex '.*' -exec /bin/sed -i 's#REPLACELBPHTMLAUTHDIR#$lbhomedir/webfrontend/htmlauth/plugins/$pfolder#g' {} \\; 2>&1");
    $message =  $SL{'PLUGININSTALL.INF_REPLACEING'} . " REPLACELBPHTMLDIR in $target";
    &loginfo;
    system("$sudobin -n -u $user $findbin $target -type f -iregex '.*' -exec /bin/sed -i 's#REPLACELBPHTMLDIR#$lbhomedir/webfrontend/html/plugins/$pfolder#g' {} \\; 2>&1");
    $message =  $SL{'PLUGININSTALL.INF_REPLACEING'} . " REPLACELBPTEMPLATEDIR in $target";
    &loginfo;
    system("$sudobin -n -u $user $findbin $target -type f -iregex '.*' -exec /bin/sed -i 's#REPLACELBPTEMPLATEDIR#$lbhomedir/templates/plugins/$pfolder#g' {} \\; 2>&1");
    $message =  $SL{'PLUGININSTALL.INF_REPLACEING'} . " REPLACELBPDATADIR in $target";
    &loginfo;
    system("$sudobin -n -u $user $findbin $target -type f -iregex '.*' -exec /bin/sed -i 's#REPLACELBPDATADIR#$lbhomedir/data/plugins/$pfolder#g' {} \\; 2>&1");
    $message =  $SL{'PLUGININSTALL.INF_REPLACEING'} . " REPLACELBPLOGDIR in $target";
    &loginfo;
    system("$sudobin -n -u $user $findbin $target -type f -iregex '.*' -exec /bin/sed -i 's#REPLACELBPLOGDIR#$lbhomedir/log/plugins/$pfolder#g' {} \\; 2>&1");
    $message =  $SL{'PLUGININSTALL.INF_REPLACEING'} . " REPLACELBPCONFIGDIR in $target";
    &loginfo;
    system("$sudobin -n -u $user $findbin $target -type f -iregex '.*' -exec /bin/sed -i 's#REPLACELBPCONFIGDIR#$lbhomedir/config/plugins/$pfolder#g' {} \\; 2>&1");
    $message =  $SL{'PLUGININSTALL.INF_REPLACEING'} . " REPLACELBPBINDIR in $target";
    &loginfo;
    system("$sudobin -n -u $user $findbin $target -type f -iregex '.*' -exec /bin/sed -i 's#REPLACELBPBINDIR#$lbhomedir/bin/plugins/$pfolder#g' {} \\; 2>&1");

  # File
  } else {

    $message =  $SL{'PLUGININSTALL.INF_REPLACEING'} . " REPLACELBHOMEDIR in $target";
    &loginfo;
    system("$sudobin -n -u $user /bin/sed -i 's#REPLACELBHOMEDIR#$lbhomedir#g' $target 2>&1");
    $message =  $SL{'PLUGININSTALL.INF_REPLACEING'} . " REPLACELBPPLUGINDIR in $target";
    &loginfo;
    system("$sudobin -n -u $user /bin/sed -i 's#REPLACELBPPLUGINDIR#$pfolder#g' $target 2>&1");
    $message =  $SL{'PLUGININSTALL.INF_REPLACEING'} . " REPLACELBPHTMLAUTHDIR in $target";
    &loginfo;
    system("$sudobin -n -u $user /bin/sed -i 's#REPLACELBPHTMLAUTHDIR#$lbhomedir/webfrontend/htmlauth/plugins/$pfolder#g' $target 2>&1");
    $message =  $SL{'PLUGININSTALL.INF_REPLACEING'} . " REPLACELBPHTMLDIR in $target";
    &loginfo;
    system("$sudobin -n -u $user /bin/sed -i 's#REPLACELBPHTMLDIR#$lbhomedir/webfrontend/html/plugins/$pfolder#g' $target 2>&1");
    $message =  $SL{'PLUGININSTALL.INF_REPLACEING'} . " REPLACELBPTEMPLATEDIR in $target";
    &loginfo;
    system("$sudobin -n -u $user /bin/sed -i 's#REPLACELBPTEMPLATEDIR#$lbhomedir/templates/plugins/$pfolder#g' $target 2>&1");
    $message =  $SL{'PLUGININSTALL.INF_REPLACEING'} . " REPLACELBPDATADIR in $target";
    &loginfo;
    system("$sudobin -n -u $user /bin/sed -i 's#REPLACELBPDATADIR#$lbhomedir/data/plugins/$pfolder#g' $target 2>&1");
    $message =  $SL{'PLUGININSTALL.INF_REPLACEING'} . " REPLACELBPLOGDIR in $target";
    &loginfo;
    system("$sudobin -n -u $user /bin/sed -i 's#REPLACELBPLOGDIR#$lbhomedir/log/plugins/$pfolder#g' $target 2>&1");
    $message =  $SL{'PLUGININSTALL.INF_REPLACEING'} . " REPLACELBPCONFIGDIR in $target";
    &loginfo;
    system("$sudobin -n -u $user /bin/sed -i 's#REPLACELBPCONFIGDIR#$lbhomedir/config/plugins/$pfolder#g' $target 2>&1");
    $message =  $SL{'PLUGININSTALL.INF_REPLACEING'} . " REPLACELBPBINDIR in $target";
    &loginfo;
    system("$sudobin -n -u $user /bin/sed -i 's#REPLACELBPBINDIR#$lbhomedir/bin/plugins/$pfolder#g' $target 2>&1");

  }

  return();

}

#####################################################
# Conerting all files to unix fileformat
#####################################################

# &dos2unix ("loxberry", "1", "path/to/folder");

sub dos2unix {

  my $user = shift;
  my $recursive = shift;
  my $target = shift;

  # Folder
  if ($recursive) {

    system("$sudobin -n -u $user $findbin $target -type f -iregex '.*' -exec $dos2unix {} \\; 2>&1");

  # File
  } else {

    system("$sudobin -n -u $user $dos2unix $target 2>&1");

  }

  return();

}


#####################################################
# Sorting Plugin Database
#####################################################

sub sort_plugins {
  # Einlesen
  my @zeilen=();
  my $input_file="$lbhomedir/data/system/plugindatabase.dat";
  open (F, '<', $input_file) or die "Fehler bei open($input_file) : $!";
  while(<F>)
  {
     chomp($_ );
     push @zeilen, [ split /\|/, $_, 9 ];
  }
  close (F);

  # Sortieren
  my $first_line=shift(@zeilen);
  @zeilen=sort{$a->[6] cmp $b->[6]}@zeilen; 
  unshift(@zeilen, $first_line);

  # Ausgeben    
  open(F,"+<$lbhomedir/data/system/plugindatabase.dat");
  flock(F,2);
  @data = <F>;
  seek(F,0,0);
  truncate(F,0);
  print F join('|', @{$_}), "\n" for @zeilen;   #sortiert wieder ausgeben
  flock(F,8);
  close (F);
  return();
}
