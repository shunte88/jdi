#!/usr/bin/perl -w
#
# hbtranscode.pl v1.0.5
#
# 2014-03-21 Initial, transcode large multi GB 1080p content to 480p
# 2014-03-29 Move transcoded media directly to the NAS (archive)
# 2014-08-22 Added Title tagging, still researching if can be done 1st pass
# 2016-01-08 Moved from HTPC to klunker laptop and utilize HEVC codec and 720p
# 2016-04-10 Use PushBullet notifications to mobile
# 2017-09-09 Moved to the myth2017 build - improve multi-worker capabilities
# 2017-09-09 Added lock file mechanism for multiple workers
# 2017-09-09 Add soft kill swith through earlydoors trigger file mechanism
# 2017-09-12 Auto-rename additions
# 2018-01-08 Fix date delta
#

use strict;
use warnings;
use Cwd qw( abs_path );
use File::Path;
use File::Copy;
use File::Find::Rule;
use File::Basename;
use Env;
use Getopt::Long;
###use Net::PushBullet;
use WWW::PushBullet;
use Date::Calc qw(Delta_DHMS);
use File::Touch;
use Sys::Hostname;
use YAML::Tiny;

#use Net::Domain qw(hostname)
#use Data::Dumper;

$SIG{TERM} = \&close_handler;
$SIG{HUP} = \&close_handler;
$SIG{KILL} = \&close_handler;

my $VERSION     = '1.0.5';
my $verbose;
my $log         = '/tmp/transcode.large.log';
my $days        = 1;
#my $window      = time()-($days*24*60*60);
my $window      = time()-(18*60*60);
my $myth_video  = $ENV{"HB_MYTH_BASE_FOLDER"}; #'/mnt/myth01/';
my $NAS_mount   = $ENV{"HB_NAS_MOUNT"};        #'/mnt/FN24Z';        # NAS - always mounted so just safety
my $NAS_dir     = $ENV{"HB_NAS_BASE_FOLDER"};  #'/mnt/FN24Z/F8NAS1'; # NAS - always mounted so just safety
my $looksee     = join('-',safe_shell('df'));
my $look_NAS    = index($looksee, $NAS_mount);
my $archive     = "$NAS_dir/video/tv/";
my $iphone      = $ENV{"HB_PB_DEVICE_ID"};

my $cutoff      = $ENV{"HB_CUTOFF_HOUR"};
$cutoff=22 unless$cutoff;
my $today       = 0;

my $staging     = '/tmp/';
my $pidnum      = "$$";
my $stagedFile  = "$staging/$pidnum.staging.mpeg";
my $processFile = '';
my $lockFile    = '';
my $chapterFile = "$staging/$pidnum.staging.csv";

my $earlyDoors  = '/home/stuart/earlydoors.txt';
my $mkvExt      = '.mkv';

my $start_size  = 1;
my $final_size  = 1;

my $debug       = 0;
my $usestaged   = 1;
my $hevc        = 1;
my $push_note   = 1;

###my $pb = Net::PushBullet->new(key_file=>'/home/stuart/.pushbulletrc',device_id=>$iphone);

my $yaml = YAML::Tiny->read( '/home/stuart/pushbullet.yml' );
my $config = $yaml->[0];
my $apikey = $yaml->[0]->{auth};
my $pb = WWW::PushBullet->new({apikey => $apikey});

GetOptions (
  'hevc=i'       => \$hevc,      # go x265
  'stagelocal=i' => \$usestaged, # stage file locally
  'pushbullet=i' => \$push_note, # use push bullet notifications
  'debug=i'      => \$debug,     # emulate only
  'verbose=i'    => \$verbose,   # chatty
);

open LOGFILE, '>>', $log;

sub close_handler
{
  if ((''ne$lockFile) && (-e $lockFile)) {
    cleanupFile($lockFile)
  }
}

sub getLogTimestamp
{
  my ($sec, $min, $hour, $mday, $mon, $year) = localtime;
  my $timestamp =
       sprintf("[%4d/%02d/%02d %02d:%02d:%02d]", $year+1900, $mon+1, $mday, $hour, $min, $sec);
  return $timestamp;
}

sub logPrint
{
  print LOGFILE getLogTimestamp,' ',@_,"\n";
  print @_,"\n";
}

sub prettyBytes {
 my $size = $_[0];
 foreach ('b','KiB','MiB','GiB','TiB','PiB')
 {
    return sprintf("%.2f",$size)."$_" if $size < 1024;
    $size /= 1024;
 }
}

sub logPrintBeg
{
  print LOGFILE getLogTimestamp,'>',@_,"\n";
  print '>',@_,"\n";
}

sub logPrintEnd
{
  print LOGFILE getLogTimestamp,'<',@_,"\n";
  print '<',@_,"\n";
}

sub pushPrintEnd
{
  my($event,$message)=@_;
  ###$pb->push_note(hostname."::$event",$message);
  $pb->push_note(
    {
        device_iden => $iphone,
        title       => hostname."::$event",
        body        => $message
    }
    );
  $message = $event unless $message;
  logPrintEnd $message;
}

sub pushPrint
{
  my($event,$message)=@_;
  ###$pb->push_note(hostname."::$event",$message);
  $pb->push_note(
    {
        device_iden => $iphone,
        title       => hostname."::$event",
        body        => $message
    }
    );

  $message = $event unless $message;
  logPrint $message;
}

sub cleanupFile {
  my($file,$logIt)=@_;
  if (-e $file) {
    logPrintEnd "Cleanup $file" if(defined $logIt);
    unlink $file;
  }
}

sub uniqueFilename($;$) 
{
  my ($filename,$ext) = @_;
  $ext='.mpeg'unless$ext;
  my $count = 0;
  my ($file,$path,$extx) = fileparse($filename,($ext));
  do { 
    $count++;
    $filename = "$path/$file-$count$ext";
  } while ((-e $filename)&&($count<=200)); # count test pure safety
  logPrint "Auto-rename: $filename";
  return $filename;
}

sub fixName($) {
  my $file = shift;
  $file =~ s/.mpeg$//i;
  return $file;
}

# copy file local - reduce network overhead
sub copyToStage {
  if(!(-e "$processFile.lck")) {
    if(1==$usestaged) {
      $stagedFile = "$staging/$pidnum.staging.mpeg";
      cleanupFile($stagedFile);
      logPrintBeg "Copy $processFile to staging";
      copy($processFile,$stagedFile);
      logPrintEnd 'Done';
    } else {
      $stagedFile=$processFile;
    }
    $lockFile="$processFile.lck";
    logPrintBeg "Lock file $lockFile";
    touch($lockFile);
  }
  $start_size = (stat $stagedFile)[7]; 
  logPrint "Init ".prettyBytes($start_size);
  return((-e $stagedFile)?1:0);
}

sub chapterTitle($) {
  my $title = shift;
  cleanupFile($chapterFile); # redundant but safe
  open CSV, '>', $chapterFile;
  $title =~ s/^.*\///;
  $title =~ s/\./ /g;
  print CSV "1,$title\n";
  close CSV;
  return $title;
}

sub safe_shell
{
  open my $fh, '-|', @_ or die "Can't open pipe for [safe] shell: $!";
  my @out = <$fh>;  # or read in a loop, which is more likely what you want
  #close $fh or die "Can't close pipe: $!";
  close $fh or print "Can't close pipe: $!\n"; # we want to send the email so don't die
  return @out;
}

sub makePathWithTest($)
{
  my($path)=@_;
  if(!(-e $path))
  {
    eval { mkpath($path) };
    if ($@) {
      print "Couldn't create $path: $@";
      return 0;
    }
  }
  return 1;
}

sub pluralize($) 
{
  my $test = shift;
  return (1==$test)?'':'s';
}

if (-1!=$look_NAS) {

  chdir("$myth_video/"); # want files specs returned relative to the base folder, see below
  logPrintBeg "$myth_video";
  #logPrintBeg dirname(abs_path($0));

  my @filez  = map  { $_->[1] }             # names
             sort { $a->[0] cmp $b->[0] }   # oldest...newest, should transcode in sequence as applicable
             map  { [(stat($_))[9], $_] }   # mdate, name
             grep { !/^kik/ } File::Find::Rule->file
                    ->name('*.mpeg','*.MPEG','*.mpeg.mkv')
                    ->mtime("<=$window")
                    ->size('>600M')
                    ->in('.');              # paths returned will be relative video folder, we'll re-path!

  if(0!=scalar (@filez)) {

    foreach(@filez) {

      my $filename = fixName($_);

      logPrintBeg "Filename:: $filename";

      # need to ensure we have the path defined
      my (undef,$folder) = fileparse($filename);
      makePathWithTest("$archive/$folder");

      $processFile = "$myth_video/$filename.mpeg";

      if(copyToStage()) {

        my $title = chapterTitle($filename);
        pushPrint "Transcode Processing \"$title\"";

        my ($sec1, $min1, $hour1, $mday1, $mon1, $year1) = localtime;

        my $vwidth = '';
        my@info=safe_shell("mplayer -nolirc -identify -vo null -ao null -frames 0 \"$stagedFile\" </dev/null | grep -i -e \"^ID_\"");
        my%vinfo = map { chomp; split( /=/, $_, 2 ) } @info;

        # if 1080 -> 720, 720 and SD keep as is
        logPrint 'Video Height::',$vinfo{ID_VIDEO_HEIGHT};
        if (1080==$vinfo{ID_VIDEO_HEIGHT}) {
          $vwidth = '--width 1280';
        } else {
          $vwidth = '--width '.$vinfo{ID_VIDEO_WIDTH}.' --height '.$vinfo{ID_VIDEO_HEIGHT};
        }

        my $archFile = "$archive/$filename$mkvExt";
        # auto-rename if exists
        $archFile=uniqueFilename($archFile,$mkvExt) if (-e "$archFile");
        
        my$cmd = "nice -n19 /usr/bin/HandBrakeCLI";
        $cmd = $cmd." -i \"$stagedFile\" -o \"$archFile\"";

        my $preset = 'H.265 MKV 720p30';
        if(0==$hevc) {
          $preset = 'H.265 MKV 480p30';
        } else {
          $preset = 'H.265 MKV 720p30';
          ###$cmd = $cmd." --preset=\"H.265 MKV 720p30\""; #$vwidth --crop 0:0:0:0 --loose-anamorphic --modulus 2 -e x265 -q 20 --vfr -a 1,2 -E av_aac,av_aac --audio-fallback ac3 --encoder-preset=veryfast";
        }
        $cmd = $cmd." --preset=\"$preset\" -f mkv ";
        $cmd = $cmd." --markers=\"$chapterFile\" " if (-e $chapterFile);
        $cmd = $cmd.' 2> /dev/null ';

        logPrintBeg $cmd;

        # get the result, ensure we're good
        if(!(-e "$archFile")){
          system($cmd);
          $today++;
        }

        # test the new file exists and if of an expected size
        if (-e "$archFile") {
          # check the file is of a reasonable size > 200Mi
          $final_size = (stat "$archFile")[7]; 
          if ($final_size > 200000) {
            cleanupFile($processFile,1);
          }

          # set the title tag
          $cmd = "mkvpropedit $archFile --edit info --set \"title=$title\" 2> /dev/null ";
          logPrintBeg $cmd;
          system($cmd);

        }

        cleanupFile($stagedFile,1);
        cleanupFile($chapterFile,1);
        cleanupFile($lockFile,1);

        my ($sec2, $min2, $hour2, $mday2, $mon2, $year2) = localtime;

        my ($days, $hours, $min, $sec) = Delta_DHMS (
                                           $year1+1900, $mon1+1, $mday1, $hour1, $min1, $sec1,
                                           $year2+1900, $mon2+1, $mday2, $hour2, $min2, $sec2
                                         );


        pushPrintEnd "Processed \"$title\"\nElapsed $hours hours, $min minutes, and $sec seconds\n".
          'Using preset: "'."$preset\"\n".
          "File size saving:\n".
            prettyBytes($start_size).' to '.
            prettyBytes($final_size).', '.(sprintf("%.3f", ((($start_size-$final_size)/$start_size)*100)))."%\n".
          sprintf("Processed %d file%s today.\n",$today,pluralize($today));

      } else {
        logPrintEnd 'No staging file found, likely locked by partner process - skipping...';
      }

      if(-e $earlyDoors) {
        cleanupFile($earlyDoors,1);
        logPrintEnd 'Early Doors!';
        last;
      }

      my $hour = (localtime)[2];
      my $wday = (localtime)[6];

      # if after 10PM shutdown - we're scheduled for a 1AM refresh
      #if (($hour>=18) || ( ( ($wday==0) || ($wday==6) ) && ($hour>=12) ) ) {
      if ($hour>=$cutoff) {
        last;
      }

    }  
  }
  else
  {
    pushPrintEnd 'No files to transcode';
  }
}
else
{
  pushPrintEnd "NAS is not mounted\nTranscode Aborted";
}

logPrintEnd 'Done';
close LOGFILE;

exit(0);


