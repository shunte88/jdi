#!/usr/bin/perl -w
#

# call via
#  ~/unrarall.pl -f /data/videos/
#  2018.11.05 minor rewrite for 2016 7zip

use strict;
use Env;
use File::Find;
use File::Find::Rule;
use Getopt::Long;
use File::Basename 'fileparse';
use File::Copy;
use File::Slurp;
use File::Path;
use tvtitle 'titleParse';

my$folder;
my@filetype=qw(avi mkv mpeg mp4 m4v mpg webm);

GetOptions (
  'folder:s' => \$folder
);

if ((!(defined $folder))||(!(-d $folder))) {
  print "Specify an existing folder\ne.g. $0 -f /var/lib/mythtv/videos/\n\n";
  exit -1;
}

sub safe_shell
{
  open my $fh, '-|', @_ or die "Can't open pipe for [safe] shell: $!";
  my @out = <$fh>;  # or read in a loop, which is more likely what you want
  close $fh;# or die "Can't close pipe: $!";
  return @out;
}

sub makePathWithTest($)
{
  my($path)=@_;
  if(!(-e $path))
  {
    eval { mkpath($path,'0777') };
    if ($@) {
      print "Couldn't create $path: $@";
      return 0;
    }
    system('chmod -fR 0777 "'.$path.'/"'); #safe
  }  
  return 1;
}

sub sanitizeName
{
  my($filename)=@_;

    my ($name,$path,$suffix) = fileparse($filename,@filetype);
    $path=$folder if ('./'eq$path);
    my $show = $name;
    if ($name =~ m/\.s\d{1,2}e\d{1,2}(\.|$)/i){
      $name =~ /(.*).s\d{1,2}e\d{1,2}/i;
      $show = "$1";
    }
    if ($path ne $folder.$show.'/') {
      print "Evaluate : $path/$name.$suffix\n";
      makePathWithTest($path.'/'.$show);
      $show = $show.'/'.$name.'.'.$suffix;
      $show = $path.$show if ('./'ne$path);
      $name = $name.'.'.$suffix;
      $name = $path.$name if ('./'ne$path);
      $name = $show if ($name ne $show);
    } else { 
      $name = $filename;
    }
    $filename = $name if ($filename ne $name);

  return $filename;
}

sub doRename 
{

  my($oldname,$replace)=@_;
  my $filename = $oldname;
  $filename =~ s/\s+CRC Failed//ig;
  if($filename =~ m/(avi|mkv|mpeg|mp4|m4v|mpg|webm)$/i) {

    if (-e "$folder/$oldname") {
    
      my ($name,$path,$suffix) = fileparse($oldname,@filetype);

      $name = tvtitle::titleParse($name,'n',$replace);
      if((defined $path)and('./'ne$path)) {
        $path = tvtitle::titleParse($path,'d',$replace);
      } else {
        $path = tvtitle::titleParse($name.'/','d',$replace);
      }
      
      $filename = sanitizeName($name.lc($suffix));

      if (($filename ne $oldname)and(''ne$filename)and(lc($suffix)ne$filename)){
        print "Move $oldname -> $filename\n";
        move("$folder/$oldname","$filename");
        $oldname = $filename;
      }

    }
  }
    
  return $oldname;
}

sub goRename
{
  my($filename)=@_;
  my $go = 1;
  if (-e "$folder/$filename") {
    $filename = doRename($filename,'720p');
    if($filename =~ m/\.mkv$/i) {
      my ($name,$path,$suffix) = fileparse($filename,qw(avi mkv mpeg mp4 m4v mpg webm));
      $name =~ s/\./ /g;
      system("mkvpropedit $filename --edit info --set \"title=$name\" 2> /dev/null ");
    }
    system('chmod -fR 0777 "'.$folder.'/'.$filename.'"');
    system('touch "'.$filename.'"');
  }
  return $filename;
}

sub getPayload
{
  my($archive,$position)=@_;
  my $scratch = '/tmp/cronkpayload.txt';
  my $cmd = '7z l "'.$archive.'" > '.$scratch.' && awk \'/(.mkv|.avi|.mp4|.mpg|.mpeg|.m4v)$/ {print substr($0,54,200)}\' '.$scratch;
  #print "$cmd\n";
  my @content=safe_shell($cmd);
  my $result = $content[0];
  $result =~ s/\r?\n|\r//g;
  unlink $scratch;
  return $result;
}

# off we go...

chdir($folder);
my @filez  =  grep { !/.part(2|3|4|5|6|7|8).rar/ } File::Find::Rule->file
               ->name('*.rar')
               ->size('> 0')
               ->in('.')
               #->maxdepth(1)
               ;


# unrar all we find
if(0!=scalar (@filez)) {
  foreach(@filez) {
    if (($_ !~ m/www\.NewAlbumReleases\.net/) && ($_ !~ m/^LMA/) && ($_ !~ m/CD-FLAC/) ) {
      my $test = index($_,'/'); # single level only
      if (-1 == $test) {

        my $archfile = $_;

        # some tomfoolery here with rar that have no timestamps on contained files
        # now redundant as we use positional logic substr which also handles files in folders

        my $position = 8;
        my $extract = '';

        while ((length($extract) <= 2)&&($position != 2)) {
          $position = $position - 2; # name position 6, and failing that, 4 if no timestamp
          $extract = getPayload($archfile,$position);
        }

        if ($position >= 4) {
          my $cmd = "7z e -aoa '-i!$extract' \"$archfile\"";
          print "$cmd\n";
          my@result=safe_shell($cmd);
          $extract = goRename($extract);

        }

      }
    }
  }
}

# de-crapify, with selected file extracts this should be redundant - here for completion
my @clean  = File::Find::Rule->file
             ->name('picasa.ini','desktop.ini','thumbs.db','AlbumArt*.jpg','Thumbs.db','release.url','rapidpornz.url','rapidmoviez.url','info.txt','Release.Url','Rapidmoviez.Url','Info.Txt','Thanks_You_For_Download.txt', '*.nfo','*.Nfo','*.sub','*.idx','*.srt','Pos.Delete.Me.*','Rarbg.com.avi')
             ->in('.');
if(0!=scalar (@clean)) {
  unlink "$folder/$_" foreach(@clean);
}

# now remove empty folders

finddepth(sub { 
  return unless -d;
  ####print "Burn $_\n";
  rmdir "$_/Subs" if (-d "$_/Subs");
  rmdir "$_/subs" if (-d "$_/subs");
  rmdir $_;
}, $folder);

exit 0;


