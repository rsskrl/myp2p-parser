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

my $mythtv_dir = $ENV{'HOME'} ? $ENV{'HOME'}.'/.mythtv' : undef;
my (@matched_categories, @ignore_categories, $min_bitrate, @cats, %cats):shared;
my ($proxy, $quiet, $help);

GetOptions(
	'mythtv-dir:s'			=> \$mythtv_dir,
	'sopcast-player:s'		=> \$players{Sopcast},
	'veetle-player:s'		=> \$players{Veetle},
	'flash-player:s'		=> \$players{Flash},
	'media-player:s'		=> \$players{MediaPlayer},
	'min-bitrate:i'			=> \$min_bitrate,
	'c|match-category:s'		=> \@matched_categories,
	'i|ignore-category:s'		=> \@ignore_categories,
	'proxy:s'			=> \$proxy,
	'q|quiet'			=> \$quiet,
	'h|help'			=> \$help
);

if ($help) {
	print "wizwig.tv webpage parser which gets all playable links for the shows\n\n";
	print "Syntax: ".$0." [OPTION]... [URL]\n\n";
	print "if URL is not passed \"$URL\" will be used by default\n\n";
	print "Options:\n";
	print "       --mythtv-dir=DIR                   create XML code for MythTV menu and save it in this dir ($mythtv_xml_file*.xml). Default: $mythtv_dir\n\n";
	print "       Players for MythTv menu:\n";
	print "           --sopcast-player=COMMAND           open Sopcast streams (sop://) with this command. Default: ".$players{Sopcast}."\n";
	print "           --flash-player=COMMAND             open webpages with Flash streams with this command. Default: ".$players{Flash}."\n";
	print "           --veetle-player=COMMAND            open webpages with Veetle streams with this command. Default: ".$players{Veetle}."\n";
	print "           --media-player=COMMAND             open MediaPlayer (mms://) streams with this command. Default: ".$players{MediaPlayer}."\n\n";
	print "       --min-bitrate=[BITRATE IN KB]      all streams with bitrate lower than this minimum bitrate will be ignored. Default is 0 (none will be ignored)\n";
	print " -c    --match-category=[CATEGORY]        get streams only for matched categories (sports). all other categories will be ignored. Multiple catgories can be set (-c ... -c ...)\n";
	print " -i    --ignore-category=[CATEGORY]       ignore these categories (sports). Multiple categories can be set (-i ... -i ...)\n";
	print "       --proxy=PROXY[:PORT]               proxy for downloading pages\n";
	print " -q,   --quiet                            do not output any info/debug messages\n";
	print " -h,   --help                             show this help\n\n";
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

	my $cnt = 0;
	foreach my $cat (@cats) {
		my $catmenu = qq(<mythmenu name="MYP2P_MENU_).(++$cnt).qq(">);
		my $mythtv_catmenu = $mythtv_xml_file.$cnt.".xml";

		foreach my $event (@{$cat->{events}}) {
			my $submenu = qq(<mythmenu name="MYP2P_MENU_).(++$cnt).qq(">);

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

			my $mythtv_submenu = $mythtv_xml_file.$cnt.".xml";
			open MYTHTV_SUBMENU, '>', "$mythtv_dir/$mythtv_submenu";
			print MYTHTV_SUBMENU $submenu."\n";
			close MYTHTV_SUBMENU;
			debug("Created $mythtv_dir/$mythtv_submenu");

			$catmenu .= qq(
				<button>
					<type>VIDEO_BROWSER</type>
					<text>$event->{title}</text>
					<action>MENU $mythtv_submenu</action>
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
	debug("Checking link: $link");

	my $tb = get_tree($link);
	next if !$tb;

	my @links :shared; 
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
			title => $title,
			links => \@links
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
