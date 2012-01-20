#!/usr/bin/perl

#############################################################################
#  
# wizwig.tv webpage parser which gets all SOP, MMS, Veetle links for 
# the streams.
#
# this version sorts event by category (sport)
#
# run --help for more info
#
#############################################################################
# change whatever you wish if you know what are you doing

use warnings;
use strict;
use Getopt::Long;
use LWP::UserAgent;
use HTML::TreeBuilder;
use LWP::Simple;
use Config;
use threads;
use threads::shared;
use File::Spec::Functions qw/rel2abs/;
use File::Basename;
use Data::Dumper;
use utf8;


my $URL =  'http://www.wiziwig.tv/index.php?part=sports';
my %players :shared = ( 
	'Sopcast'	=> ($ENV{'HOME'} ? $ENV{'HOME'}.'/sopcast-play.sh' : '~/sopcast-play.sh'),
	'Veetle'	=> '/usr/bin/google-chrome --kiosk',
	'Flash'		=> '/usr/bin/google-chrome --kiosk',
	'MediaPlayer'	=> '/usr/bin/mplayer -fs'
);

# every mythtv xml file begins with this name
my $mythtv_xml_file = "myp2p_parser_";

my $execparser = rel2abs($0);
my $mythtv_dir = $ENV{'HOME'} ? $ENV{'HOME'}.'/.mythtv' : undef;
my (@matched_categories, @ignore_categories, $min_bitrate, @cats, %cats):shared;
my ($refresh_stream, $stream_url, $stream_file):shared;
my ($proxy, $quiet, $help);

GetOptions(
	'mythtv-dir:s'			=> \$mythtv_dir,
	'mythtv-xml-file:s'		=> \$mythtv_xml_file,
	'sopcast-player:s'		=> \$players{Sopcast},
	'veetle-player:s'		=> \$players{Veetle},
	'flash-player:s'		=> \$players{Flash},
	'media-player:s'		=> \$players{MediaPlayer},
	'min-bitrate:i'			=> \$min_bitrate,
	'c|match-category:s'		=> \@matched_categories,
	'i|ignore-category:s'		=> \@ignore_categories,
	'proxy:s'			=> \$proxy,
	'q|quiet'			=> \$quiet,
	'h|help'			=> \$help,
	'refresh-stream'		=> \$refresh_stream,
	'stream-url:s'			=> \$stream_url,
	'stream-file:s'			=> \$stream_file
);

if ($help) {
	print qq/
wizwig.tv webpage parser which gets all playable links for the shows

Syntax: $0 [OPTION]... [URL]

if URL is not passed "$URL" will be used by default

Options:
       --mythtv-dir=DIR                   create XML code for MythTV menu and save it in this dir (myp2p_parser_*.xml). Default: $mythtv_dir 
       --mythtv-xml-file=PREFIX           set the prefix for MythTv menu XML files. you can use this option to create two different menus
                                          i.e. one for live sports and one for only soccer matches. Default: $mythtv_xml_file

       Players for MythTv menu:
           --sopcast-player=COMMAND           open Sopcast streams (sop:\/\/) with this command. Default: $players{Sopcast} 
           --flash-player=COMMAND             open webpages with Flash streams with this command. Default: $players{Flash} 
           --veetle-player=COMMAND            open webpages with Veetle streams with this command. Default: $players{Veetle}
           --media-player=COMMAND             open MediaPlayer (mms:\/\/) streams with this command. Default: $players{MediaPlayer}

       --min-bitrate=[BITRATE IN KB]      all streams with bitrate lower than this minimum bitrate will be ignored. Default is 0 (none will be ignored)
 -c    --match-category=[CATEGORY]        get streams only for matched categories (sports). all other categories will be ignored. Multiple catgories can be set (-c ... -c ...)
 -i    --ignore-category=[CATEGORY]       ignore these categories (sports). Multiple categories can be set (-i ... -i ...)
       --proxy=PROXY[:PORT]               proxy for downloading pages
 -q,   --quiet                            do not output any info and debug messages
 -h,   --help                             show this help

/;
	exit;

} elsif ($refresh_stream) {
	my @links = get_stream_links($stream_url);
	if (@links) {
		my $event = {
			links		=> \@links,
			stream_url	=> $stream_url
		};
		create_mythtv_stream_menu($stream_file, $event);
	}
	exit;
}

$URL = join('', @ARGV) if ($#ARGV >= 0);
debug("Using URL: $URL\n");

my $tree = get_tree($URL);
exit if !$tree;
my $nowplaying = $tree->look_down('_tag' => 'table', 'class' => 'nowplaying');
exit if !$nowplaying;

my @jobs;
foreach ($nowplaying->look_down('_tag' => 'tr', 'class' => qr/\b(odd|even)\b/i)) {
	push @jobs, threads->create(\&get_links, $_);
}
$_->join for @jobs;

# create mythtv menus
if (@cats && $mythtv_dir && -d $mythtv_dir) {
	# delete old existing xmls
	my @oldxmls = glob("$mythtv_dir/$mythtv_xml_file*.xml");
	foreach my $oldxml (@oldxmls) {
		debug("Deleting $oldxml");
		unlink "$oldxml";
	}

	my $mythtv_menu = "$mythtv_dir/$mythtv_xml_file"."main.xml";
	open MYTHTV_MENU, '>', $mythtv_menu;
	print MYTHTV_MENU qq(<mythmenu name="MYP2P_MENU">);

	print MYTHTV_MENU qq(
		<button>
			<type>VIDEO_BROWSER</type>
			<text>Refresh All Streams</text>
			<action>EXEC $execparser</action>
		</button>
	);

	my $cnt = 0;
	foreach my $cat (@cats) {
		my $catmenu = qq(<mythmenu name="MYP2P_MENU_).(++$cnt).qq(">);
		my $mythtv_catmenu = $mythtv_xml_file.$cnt.".xml";

		foreach my $event (@{$cat->{events}}) {
			my $mythtv_submenu = $mythtv_xml_file.(++$cnt);
			create_mythtv_stream_menu("$mythtv_dir/$mythtv_submenu", $event);

			$catmenu .= qq(
				<button>
					<type>VIDEO_BROWSER</type>
					<text>$event->{title}</text>
					<action>MENU $mythtv_submenu.xml</action>
				</button>
			);

		}
		$catmenu .= qq(</mythmenu>);
		open MYTHTV_CATMENU, '>', "$mythtv_dir/$mythtv_catmenu";
		print MYTHTV_CATMENU $catmenu."\n";
		close MYTHTV_CATMENU;
		debug("Created $mythtv_dir/$mythtv_catmenu");

		print MYTHTV_MENU qq(
			<button>
				<type>VIDEO_BROWSER</type>
				<text>$cat->{category}</text>
				<action>MENU $mythtv_catmenu</action>
			</button>
		);
	}
	print MYTHTV_MENU qq(</mythmenu>);
	close MYTHTV_MENU;
	debug("Created $mythtv_menu");

} elsif (@cats) {
	warn Dumper @cats;
} else {
	debug("Nothing found...");
}

sub create_mythtv_stream_menu {
	my ($file, $event) = @_;
	if ($file =~ m/^(.*)\.xml$/) {
		$file = $1;
	}
	my $menu_name = uc basename($file);
	$event->{stream_url} =~ s/&(?!amp;)/&amp;/gi;
	
	my $submenu = qq(
		<mythmenu name="$menu_name">
			<button>
				<type>VIDEO_BROWSER</type>
				<text>Refresh Stream</text>
				<action>EXEC $execparser --refresh-stream --stream-file "$file" --stream-url "$event->{stream_url}" --quiet</action>
			</button>
	);

	my $scnt = 0;
	foreach (@{$event->{links}}) {
		my $info = '';
		if ($_->{type} eq 'Sopcast') {
			$info = 'SOP';
		} elsif ($_->{type} eq 'MediaPlayer') {
			$info = 'MMS';
		} elsif ($_->{type} eq 'Flash') {
			$info = 'FLA';
		} elsif ($_->{type} eq 'Veetle') {
			$info = 'VEE';
		}

		$submenu .= qq(
			<button>
				<type>VIDEO_BROWSER</type>
				<text>).(++$scnt).qq( [$info]: $_->{kbps} kbps</text>
				<action>EXEC $_->{player} $_->{href}</action>
			</button>
		);
	}
	$submenu .= qq(</mythmenu>);

	$file .= ".xml";
	open MYTHTV_SUBMENU, '>', $file;
	print MYTHTV_SUBMENU $submenu."\n";
	close MYTHTV_SUBMENU;
	debug("Created $file");
}

sub get_stream_links {
	my $link = shift;

	debug("Checking link: $link");

	my $tb = get_tree($link);
	return if !$tb;

	my @links; 
	foreach my $tr ($tb->look_down('_tag' => 'tr', 'class' => qr/\b(odd|even)\b/)) {
		my %link :shared; 

		my @a = $tr->look_down('_tag' => 'a', 'class' => qr/\bbroadcast\b/, 'href' => qr/^(sop|mms|https?):/);
		next if !@a;
		my @kbps = $tr->look_down('_tag' => 'td', sub { $_[0]->as_text() =~/kbps/i });

		my $prev = $tr->left();
		if ($prev && $prev->attr('class') =~ m/\bstationname\b/i) {
			$link->{station}= $prev->as_text();
		}

		$link{'href'} = $a[0]->attr('href');
		$link{'kbps'} = ( $kbps[0] && $kbps[0]->as_text() =~/(\d+)\skbps/i ? $1 : '???' );
	
		if ($min_bitrate && ($link{'kbps'} eq '???' || $link{'kbps'} < $min_bitrate)) {
			debug("Ignoring stream link. Bitrate too low ($link{'kbps'} < $min_bitrate)");
			next;
		}

		# ignore useless links
		if ($link{'href'} =~ m/^https?:\/\/(www\.)?(forum\.wiziwig\.eu|wiziwig\.tv|ads(erver|erving)?\.|bet365|bwin|justin\.tv)/i) {
			next;
		}		

		# veetle is harder to find. check target links for veetle iframes
		if ($players{'Veetle'} && $link{'href'} =~/^http:/ && (my @veetle = $tr->look_down('_tag' => 'td', sub { $_[0]->as_text() =~/Veetle/i }))) {
			$link{'type'} = 'Veetle';

			my $vt = get_tree($link{'href'});
			next if !$vt;
			$link{href} =  undef;

			# embeded veetle iframes found?			
			if (my @viframe = $vt->look_down('_tag' => 'iframe', 'src' => qr/veetle.com\/index.php\/widget/)) {
				$link{'href'} = $viframe[0]->attr('src');

			# try alternatives: check all iframes and try one more level
			} else {
				foreach my $if ($vt->look_down('_tag' => 'iframe', 'src' => qr/^https?:/)) {
					# ignore facebook or twitter frames
					next if $if->attr('src') =~/^https?:\/\/(www\.)?((facebook|twitter)\.(com|net))/i;
	
					my $vtt = get_tree($if->attr('src'));
					next if !$vtt;

					if (my @viframe = $vtt->look_down('_tag' => 'iframe', 'src' => qr/veetle.com\/index.php\/widget/)) {
						$link{'href'} = $viframe[0]->attr('src');
						last;
					}
				}
			}

		} elsif ($players{'Flash'} && $link{'href'} =~/^https?:/) {
			$link{'type'} = 'Flash';
		} elsif ($players{Sopcast} && $link{'href'} =~/^sop:/) {
			$link{'type'} = 'Sopcast';
		} elsif ($players{MediaPlayer} && $link{'href'} =~/^mms:/) {
			$link{'type'} = 'MediaPlayer';
		} else {
			next;
		}

		if ($link{href}) {
			$link{'href'} =~ s/&(?!amp;)/&amp;/g;	
			$link{'player'} = $players{$link{'type'}};
			push @links, \%link;
		}
	}

	return @links;
}

sub get_links {
	my $item = shift;

	my $td_logo = $item->look_down('_tag' => 'td', 'class' => 'logo');
	return if !$td_logo;
	
	my $category = $td_logo->look_down('_tag' => 'img')->attr('alt');
	if (!$category) {
		$category = 'Unknown';
	}
	$category = ucfirst($category);

	if (@ignore_categories && grep(/^$category$/i, @ignore_categories)) {
		debug("\nMatched ignored category ($category). Skipping...");
		return;
	}
	if (@matched_categories && !grep(/^$category$/i, @matched_categories)) {
		debug("\nCategory ($category) not found in category list. Skipping...");
		return;
	}

	my $title = join "-", map { $_->as_text() } $item->look_down('_tag' => 'td', 'class' => qr/\b(home|away)\b/i);
	my $link = $item->look_down('_tag' => 'a', 'class' => qr/\bbroadcast\b/)->attr('href');
	if ($link =~ m|^/|i && $URL =~ m|^(https?://.*?)(/.*)$|i) {
		$link = $1.$link;
	}
	my $time = join "-", map { $_->as_text() } $item->look_down('_tag' => 'span', 'class' => 'time');

	debug("\nPreparing to check $title");

	my @links :shared = get_stream_links($link);
	if (@links) {
		@links = sort { $b->{kbps} <=> $a->{kbps} } @links;

		if (!$cats{$category}) {
			my @events :shared = ();
			my %c :shared = ( 
				category	=> $category,
				time		=> $time,
				events		=> \@events
			);
			$cats{$category} = \%c;
			push @cats, $cats{$category};
		}

		my %l :shared = (
			title		=> $title,
			links		=> \@links,
			stream_url	=> $link
		);
		push @{$cats{$category}->{events}}, \%l;
	}
}

sub get_page {
	my ($url, $die_on_error) = @_;

	debug("Downloading: $url");
	my $req = LWP::UserAgent->new();
        $req->proxy('http', $proxy) if $proxy; 
	$req->timeout(30);
	$req->show_progress(1) if !$quiet;
	my $reqresponse = $req->get($url);
	if ($reqresponse->is_error) {
		die('Could not open url') if $die_on_error;
		return 0;
	}
	return $reqresponse->decoded_content;
}

sub get_tree {
	my $html = get_page(shift());
	return 0 if !$html;

	my $tb = HTML::TreeBuilder->new();
	$tb->parse($html) or return 0;
	$tb->eof;
	return $tb;
}

sub debug {
	print shift()."\n" if !$quiet;
}
