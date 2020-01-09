#!/usr/bin/perl -w
#
# proctrans.pl v1.8
#
# mythtranscode wrapper for items with manual cutlists
# driven via db rather than current scripts driven by CLI args
#
# (sh) 20100814 initial
# (sh) 20100909 bumped cover art manipulation, not being picked up by WD !
# (sh) 20100912 added queue mech for letterbox encode on sep thread
# (sh) 20110128 added filenum attribute so media order is correct on WD
# (sh) 20120505 0.25 mythtv updates, SQL needed tweak as pseudo pk no longer works
# (sh) 20121020 addition of the playlist feature
# (sh) 20130112 interactive switch addition
# (sh) 20181003 29.1 mythtv updates
# (sh) 20181007 zero byte patch (mythcutkey)
#

use DBI;
use DBD::mysql;
use MythTV;
use Term::ANSIColor;
use File::Basename;
use File::Path;
use File::Find::Rule;
use File::Copy;
use Date::Format;
use TVDB::API;
use Getopt::Long;
use Prompt::Timeout;
use YAML::Tiny;
use strict;

###########use Data::Dumper;
use subs qw(exit);
$Term::ANSIColor::AUTORESET = 1;

# Set default values

my $yaml = YAML::Tiny->read( '/home/stuart/proctrans.yml' );
my $config = $yaml->[0];
my $basedir = $yaml->[0]->{basedir};
my $dir = $basedir;
my $showtsep = $yaml->[0]->{showtsep};
my $exeloc = $yaml->[0]->{execloc};
$exeloc = 1 unless $exeloc;
my $scanvideo = $yaml->[0]->{scanvidoe};
$scanvideo = 1 unless $scanvideo;

my $tryNoMpeg2 = $yaml->[0]->{trynompeg2};
my $MYTHCUTKEY = $yaml->[0]->{mythcutkey};
my $REMUXEXEC = $yaml->[0]->{remuxexec};
my $REMUXOPT = $yaml->[0]->{remuxopt};

my $connect = undef;
my $debug = 0;
my $playlist = 1;
my $interactive = 1;
my $dateformat='%Y%m%d%H%i%s';
my $shortformat='%Y%m%d%';
my $audiotrack='';

GetOptions (
  'playlist:i'    => \$playlist,
  'interactive:i' => \$interactive,
  'audio:s'       => \$audiotrack,
  'debug:i'       => \$debug,
);

my $date = `date +"%Y-%m-%d"`;
$date = &trim($date);

#
my $myth = new MythTV();
# connect to database
$connect = $myth->{'dbh'};
my @found;
my @files=();

# our own apikey obtained 20120414
# need simple config - next pass
my $tvdbCache = '/tmp/tvdb_cache';
my $apikey = $yaml->[0]->{tvapikey};
my $language='en';
# make sure cache dir exists
if (!-e $tvdbCache) 
{
  &makePathWithTest($tvdbCache) or die "Failed! $!\n";
}

# if TVDB offline we'll throw an exception
# initialize the TVDB "object" and catch
# subsequent calls remain robust
my $tvdb = undef;
eval{
$tvdb = TVDB::API::new($apikey, $language, "$tvdbCache/tvdb.db");
my $mirrors = $tvdb->getAvailableMirrors();
eval {
$tvdb->chooseMirrors(1);
};
};

sub exit {CORE::print color('reset');}

sub usage1 
{
  my $usage = "\nHow to use proctrans.pl : \n"
        ."$0 \n"
        ."Prior to execution create a cutlist for the shows you wish to process via the Myth Frontend\n\n"
        ."Then, just run it - it's fully automatic!\n\n"
;
  print color('bold green'),$usage,color('reset');
}

sub getXCommand($;$;$;$)
{
  my($chanid,$starttime,$filename,$audio)=@_;
  $audio=$audiotrack unless $audio;
  return "nice -n19 mythtranscode --chanid $chanid --starttime $starttime --outfile '$filename' --honorcutlist --mpeg2 $audio --allkeys --showprogress 2>&1";
}

sub getMXCommand($;$;$)
{
  my($folder,$origfile,$filename)=@_;
  return "nice -n19 $REMUXEXEC -i '$folder/$origfile' $REMUXOPT '$filename.mkv' 2>&1";
}

sub getAXCommand($;$;$)
{
  my($chanid,$starttime,$folder)=@_;
  return "nice -n19 bash $MYTHCUTKEY -c $chanid -s $starttime -o '$folder/' 2>&1";
}

sub getOriginalFilename($)
{
  my ($filename)=@_;
  my $ret = $filename;
  my ($file,$path,$ext) = fileparse($filename,('.mpeg'));
  # holes here!
  foreach my $filen(sort glob("{$path*$file*$ext}"))
  {
    $ret = $filen;
  }
  return $ret;
}

sub uniqueFilename($) 
{
  my ($filename)=@_;
  my $count = 0;
  my ($file,$path,$ext) = fileparse($filename,('.mpeg'));
  do { 
    $count++;
    $filename = "$path/$file-$count.mpeg";
  } while ((-e $filename)&&($count<=100)); # count test pure safety
  return $filename;
}

sub goProcessOrig($;$;$) 
{
  my ($chanid,$starttime,$filename)=@_;
  my $command = getXCommand($chanid,$starttime,$filename);
  print color('bold red'), "$command\n",color('bold blue') if(1==$interactive);
  system "$command";
  if (-e "$filename.map") {
    unlink("$filename.map");
  }
  print color('reset')if(1==$interactive);
  push @found,$filename;
  
}

sub goProcess($;$;$;$;$) 
{
  my ($chanid,$starttime,$filename,$folder,$origname)=@_;
  my $command = getXCommand($chanid,$starttime,$filename);
  print color('bold red'), "$command\n",color('bold blue') if(1==$interactive);
  system "$command";
  if (-e "$filename.map") {
    unlink("$filename.map");
  }

  # check the filesize, if 0 then use alt. command approach
  my $size = (stat $filename)[7];
  if (0==$size) {
  
    unlink($filename);

    if (1==$tryNoMpeg2) {

      $command = getXCommand($chanid,$starttime,$filename,' ');
      print color('bold red'), "$command\n",color('bold blue') if(1==$interactive);
      system "$command";
      if (-e "$filename.map") {
        unlink("$filename.map");
      }

    } else {

      $command = getAXCommand($chanid,$starttime,$folder);
      print color('bold red'), "$command\n",color('bold blue') if(1==$interactive);
      system "$command";
      $command = getMXCommand($folder,$origname,$filename);
      print color('bold red'), "$command\n",color('bold blue') if(1==$interactive);
      system "$command";
      unlink("$folder/$origname");
    }

  }

  print color('reset')if(1==$interactive);
  push @found,$filename;
  
}

sub trim($)
{
  my $string = shift;
  $string =~ s/^\s+//;
  $string =~ s/\s+$//;
  return $string;
}

sub sanitize($)
{
  my $string = shift;
  # need a more refined scheme
  #$string =~ s/'/\'/g;
  $string =~ s/'//g;
  $string =~ s/;//g;
  $string =~ s/\W+/./g;
  $string =~ s/\.\././g;
  $string =~ s/\.$//;
  return trim($string);
}

sub fixTitles($)
{
  my $string= shift;
  # config driven here again - externalize
  # should externalize these so we can maintain without code edits
  $string =~ s/[ |.]*-[ |.]*Aired[ |.]2005[ |.|-]01[ |.|-]03//;
  $string =~ s/[ |.]*-[ |.]*Aired[ |.]0000[ |.|-]00[ |.|-]00//;
  $string =~ s/[ ]*Aired[ |.]0000[ |.|-]00[ |.|-]00//;
  $string =~ s/[ ]*Aired[ |.]2005[ |.|-]01[ |.|-]03//;
  $string =~ s/Aired[ |.]1999[ |.|-]03[ |.|-]28/Aired.$date/; # BBC news, date subs may not be true but better than 1999!!
  $string =~ s/Aired[ |.]2009[ |.|-]07[ |.|-]19/Aired.$date/; # BBC news, date subs may not be true but better than 1999!!
  # remove the on masterpiec badging - use original program name
  #####$string =~ s/(\.| )On(\.| )Masterpiece//ig;
  $string =~ s/\.\././g;
  return trim($string);
}

sub mytime2str
{
  # bug in format.pm on ubuntu >= 8.04 - roll our own
  my ($format,$time) = @_;
  # ignore format for now, fix shortly
  my @d=localtime ($time); 
  return sprintf ("%4d%02d%02d%02d%02d%02d", $d[5]+1900,$d[4]+1,$d[3],$d[2],$d[1],$d[0]);

}

sub getFileTag
{
  $_ = substr($_[0],0,2);
  m/^([0-9][0-9])$/;
  return $1;
}

sub countFiles($)
{
  my $dir = shift;
  my $ret = 1;
  if(-d $dir)
  {
    my@files = glob("{$dir/*}");
    $ret = @files;
    my $max = -1;
    # deal with deletes and max tip etc
    # assumes range only 01-99
    foreach my$file(@files)
    {
      my ($filen,$path,$ext) = fileparse($file,('.mpeg'));
      my $val=getFileTag($filen);
      if(defined $val)
      {
        if(($val>0)&&($val>=$ret))
        {
          $ret = $val + 1;
        }
      }
    }
  }
  return (0==$ret)?1:$ret;  
}

sub enumerateFilename($)
{
   my ($filename) = @_;
   my ($file,$path,$ext) = fileparse($filename,('.mpeg'));
   return $path.'/'.sprintf("%02d",countFiles($path))."$showtsep$file$ext";
}

sub testFilename($)
{
   my ($filename) = @_;
   my ($file,$path,$ext) = fileparse($filename,('.mpeg'));
   my @files = glob("{$path*$file.mpeg}");
   return (@files>0);
}

sub promptUser($;$) 
{
   my ($promptString,$defaultValue) = @_;


#  my $res = prompt ( $question, $default, $timeout, 1 );

   if ($defaultValue) {
      print color('green'),$promptString, "[", color('bold blue'), $defaultValue, color('reset'), color('green'),"]: ",color('reset');
   } else {
      print color('green'),$promptString, ": ",color('reset');
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
  chmod 0777, $path;  
  return 1;
}

sub formatSeasonTag($;$)
{
  my($season,$episode)=@_;
  return sprintf('.S%02dE%02d.%s',$season,$episode,$showtsep);
}

sub getSeasonTag($;$;$;$;$)
{
  my($title,$subtitle,$airdate,$skipNameLookup,$origtitle)=@_;
  my$match=0;
  my $nameMatch = 0;
  eval {
    my$alttitle=''.`more ~/transpose_title.txt | grep "^$title>>"`;
    if(''ne$alttitle)
    {
      my@alt=split('>>',$alttitle);
      $alttitle=trim($alt[1]);
    }
    $title=((''ne$alttitle)?$alttitle:$title);
  };
  print color('bold green'),"TVDB lookup for '$title', please wait...\n",color('reset') if(1==$interactive);
  my($seasonNumber,$episodeNumber,$matchName);
  # look up episode by air date, we've seen badly formed XML coming back from tvDB so wrap - make smarter later
  # this we've seen go into wait state - manually patch season/episode to skip
  my @episodesByDate = $tvdb->getEpisodeByAirDate($title, $airdate);
  if (@episodesByDate) 
  {
    # get season
    foreach my $element (@episodesByDate) 
    {
      foreach my $episode (@$element) 
      {
        $match         = 1;
        $seasonNumber  = $episode->{SeasonNumber};
        $episodeNumber = $episode->{EpisodeNumber};
        $matchName     = $episode->{EpisodeName};
        last;
      }
    }
   
  }
  
  if(($seasonNumber)&&(''eq$episodeNumber))
  {
    my @episodesBySeason = $tvdb->getSeason($title, $seasonNumber);
    foreach my $element (@episodesBySeason) 
    {
      foreach my $episodeId (@$element) 
      {
        if ($episodeId) 
        {
          my $episode = $tvdb->getEpisodeId($episodeId);
          my $epname  = uc(trim($episode->{EpisodeName}));
          if ((uc($subtitle)eq$epname)||(uc($origtitle)eq$epname)) 
          {
            $nameMatch     = 1;
            $match         = 1;
            $episodeNumber = $episode->{EpisodeNumber};
            $matchName     = $episode->{EpisodeName};
            last;
          }
        }
      }
    }
  }
  return((($match+$nameMatch)>0)?formatSeasonTag($seasonNumber,$episodeNumber):$showtsep);
}


# make tvdb sure cache dir exists
if (!-e $tvdbCache) 
{
  &makePathWithTest($tvdbCache) or die "Failed! $!\n";
}

# PREPARE THE QUERY supports .24 through 29.1
my $query = "
SELECT DISTINCT -- have seen dupes???
  r.chanid chanid, 
  DATE_FORMAT(r.starttime,'$dateformat') starttme, 
  r.title title,
  (
    CASE LENGTH(TRIM(r.subtitle)) WHEN 0 
    THEN 
        CONCAT(
            '.-.Aired ',
            CASE LENGTH(TRIM(r.originalairdate)) WHEN 0
            THEN DATE_FORMAT(r.starttime,'$shortformat')
            ELSE r.originalairdate END
        )
    ELSE REPLACE(r.subtitle,'/','_') END) subtitle,
    CASE LENGTH(TRIM(r.subtitle)) WHEN 0 THEN 0 ELSE 1 END skipNameLookup,
    CASE LENGTH(TRIM(r.originalairdate)) WHEN 0
    THEN DATE_FORMAT(r.starttime,'$shortformat')
    ELSE r.originalairdate END airdate,
    p.category_type category,
    CASE WHEN r.season IS NULL OR r.season = '' THEN 0
    ELSE r.season END season,
    CASE WHEN r.episode IS NULL OR r.episode = '' THEN 0
    ELSE r.episode END episode,
    basename
FROM 
  recorded r,
  recordedprogram p 
WHERE 
  UPPER(r.recgroup) != 'DELETED' AND
  r.cutlist = 1 AND
  p.chanid = r.chanid AND
-- 0.25 and above the times on the recordedprogram table include the factor
-- for record ahead and no longer match the 'sanitized' show values 
--  p.starttime = r.starttime
  p.programid = r.programid AND
  (
    r.seriesid IS NULL OR
    r.seriesid = p.seriesid
  )
ORDER BY 
  2 ASC,
  3
";

my $query_handle = $connect->prepare($query);

# Exec the query, we'll loop and process files only with a valid cutlist
# anything that is commercial free will need to be cut too, usually 
# first and/or last few minutes, for it to be picked up
$query_handle->execute() || die "Cannot connect to database\n";

# Binds!
my($chanid, $starttime, $title, $subtitle, $skipNameLookup, $airdate, $category, $season, $episode, $origname);
$season=0;
$episode=0;
$query_handle->bind_columns(undef, \$chanid, \$starttime, \$title, \$subtitle, \$skipNameLookup, \$airdate, \$category, \$season, \$episode, \$origname);

$audiotrack = "--audiotrack $audiotrack" if (''ne$audiotrack);

# loop on resultset and captureshows prep'd for transcoding (have a cut list)
# transcoding takes a bit of time so prep the data and get out of the fetch loop
# as I've observed some db handle issues during these long ops
while($query_handle->fetch()) {

  # replace non-word characters in title with spaces, we trim too
  my $origtitle = $title;
  my $seasonTag='';
  if('movie'ne$category) {
    if(($season+$episode)>0) {
      $seasonTag = formatSeasonTag($season,$episode);
    } else {
      eval {
      $seasonTag = getSeasonTag($title,$subtitle,$airdate,$skipNameLookup,$origtitle);
      };
    }
    if (''eq$seasonTag) {
        $seasonTag = formatSeasonTag(0,0);
    }
  }

  # replace non-word characters in title/subtitle with underscores, we trim also
  $title = sanitize($title);
  $subtitle = sanitize($subtitle);

  # organize a bit better
  if (makePathWithTest("$basedir/$title"))
  {
    $dir = "$basedir/$title";
  }
  else
  {
    $dir = $basedir;
  }
  # mod permissions so web end can see this

  my $filename = "$dir/$title$seasonTag$subtitle.mpeg";
  $filename = fixTitles($filename);
  my $filenmnm = $filename;

  # with season info now populated dump the iteration mechanism - throws off the metadata scrape
  #$filenmnm = enumerateFilename($filename)if(('movie'ne$category)&&($showtsep eq $seasonTag));
  # capture these data as an record array struct
  push @files, 
  {
    base      => $dir,
    origname  => $origname,
    chanid    => $chanid,
    starttime => $starttime,
    title     => $title,
    subtitle  => $subtitle,
    filename  => $filename,
    filenmnm  => $filenmnm,
    audiotx   => $audiotrack
  };

} # fetch loop

foreach my $show(@files) {
  
  print color('bold white'),"Target filename: $show->{filename} \n",color('reset') if(1==$interactive);

  if ($debug) {
    my $command = getXCommand($show->{chanid},$show->{starttime},$show->{filename},$show->{audiotx});
    print color('green'),"\nUSING $command\n",color('reset');
    my $altcommand = getAXCommand($show->{chanid},$show->{starttime},$show->{base});
    print color('green'),"\nALTERNATE $altcommand\n",color('reset');
  }
  else
  {
    if (testFilename($show->{filename}))
    {
      my $response = 'N';
      if(1==$interactive) {
      	$response = &promptUser($show->{title}.$showtsep.$show->{subtitle}.' Exists! [R]eplace, re[N]ame or [S]kip (R/N/S)','S');
      }
      # this is now somewhat broken given the numbering scheme - think through again
      if(uc($response)eq'R') {
        goProcess($show->{chanid},$show->{starttime},getOriginalFilename($show->{filename}),$show->{base},$show->{origname});
      }
      elsif(uc($response)eq'N') {
        goProcess($show->{chanid},$show->{starttime},uniqueFilename($show->{filenmnm}),$show->{base},$show->{origname});
      }
      else
      {
        print color('bold red'),"skipping...\n",color('reset') if(1==$interactive);
      }
    }
    else
    {
      goProcess($show->{chanid},$show->{starttime},$show->{filenmnm},$show->{base},$show->{origname});
    }
  }

} # end loop

if ($debug) {
  usage1;
}
else
{
  if (-1==$#found) {
    if(1==$interactive) {
      print color('bold red'),"\nNothing to Process\n";
      usage1;
    }
  }
  else 
  {
    # output final transcoded show titles and build a playlist if requested
    # much simplified relative playlist works with all devices/software players
    # one of the oldest formats so is supported by all - caveat myth f/e stumbles - re-evaluate spiff format
    print color('bold yellow'),'Processed '.(1+$#found)." file(s)\n" if(1==$interactive);
    if(1==$playlist)
    {
      open(FLO, '>', $basedir.'/'.$date.'.m3u');
      print FLO"#EXTM3U\n";
    }
    foreach my$file(@found) 
    {
      my($filen,$path)=fileparse($file,('.mpeg'));
      if(1==$playlist)
      {
        my$rfilen = $filen;
        $filen =~ s/\./ /g;
#        $filen =~ s/_/ /g;
        $path =~ s/^$basedir//; # make relative to this files location
        $path =~ s/^\///; # not really required
        $path =~ s/\/\//\//g; # not really required
        # simple relative paths, minimal info and the hyphen we included in the filename acts as a showname/artist category - neat!
        print FLO"#EXTINF:0,$filen\n";
        print FLO"$path$rfilen.mpeg\n";
      }
      print "$filen\n";
    }
    close FLO if(1==$playlist);
    print color('reset') if(1==$interactive);
  }
}

# update video links for frontend and web server
if (1==$scanvideo)
{
    system ('sync && /usr/bin/mythutil --scanvideos');
}
# display disk usage
system ('sync && df -k') if(1==$interactive);

exit 0;

