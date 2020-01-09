#!/usr/bin/perl -w
#

use strict;
use Env;
use File::Basename 'fileparse';
use File::Copy;
use File::Slurp;
use File::Path;
use File::Find::Rule;
use tvtitle 'titleParse';

my$folder='/data/videos';
print "$folder\n";
my@filetype=qw(avi mkv mpeg mp4 m4v mpg webm);

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

sub sanitizeName
{
  my($filename)=@_;
  if($filename =~ m/(avi|mkv|mpeg|mp4|m4v|mpg|webm|wmv)$/i) {
    my ($name,$path,$suffix) = fileparse($filename,@filetype);
    foreach(read_file('/home/stuart/replace.template')) {
      $name = tvtitle::titleParse($name,'n',$_) if defined $_;
    }
    $name =~ /(.*).s\d{1,2}e\d{1,2}/i;
    my $show = "$1";
    #print "1]$path\n2]$folder$show/\n";
    if ($path ne $folder.$show.'/') {
      print "Evaluate : $filename\n";
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
  }
  return $filename;
}

sub promptUser($;$) 
{
   my ($promptString,$defaultValue) = @_;
   if ($defaultValue) {
      print "$promptString [$defaultValue]: ";
   } else {
      print "$promptString: ";
   }
   $| = 1;       # force a flush after our print
   $_ = <STDIN>; # get the input from STDIN (presumably the keyboard)
   chomp;
   if ("$defaultValue") {
      return $_ ? $_ : $defaultValue;    # return $_ if it has a value
   } else {
      return $_;
   }
}

sub safeMove
{
  my($source,$target)=@_;
  my$response=promptUser("$source -> $target",'y');
  if(uc($response)eq'Y') {
    move($source,$target);  
    if(($target =~ m/\.mkv$/i)||($target =~ m/\.mp4$/i)) {
      my ($name,$path,$suffix) = fileparse($target,@filetype);
      $name =~ s/\./ /g;
      if($target =~ m/\.mkv$/i) {
        system("mkvpropedit \"$target\" --edit info --set \"title=$name\" 2> /dev/null ");
      } else {
        system("touch \"$target\"");
      }
    } else {
      system("touch \"$target\"");
    }
  }
}

# find all the files in base folder that have pattern .sSSeEE. where S and E are ints
my @files = File::Find::Rule
              ->maxdepth( 1 )
              ->file()
                ->name( qr/.s\d{1,2}e\d{1,2}(.*).(avi|mkv|mpeg|mp4|m4v|mpg|webm)$/i )
                ->size ('> 0')
                ->in( $folder )
                ;

if(0!=scalar (@files)) {
  foreach(@files) {
    my $newName = sanitizeName($_);
    $newName =~ s/\.S00E00//ig;
    safeMove($_,$newName) if ($_ ne $newName);
  }
}

exit 0;


