#!/usr/bin/perl

#############################################################################
#  
# myp2p.eu live rss feed parser which gets all SOP, MMS, Veetle links for 
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
use XML::Simple;
use LWP::UserAgent;
use Getopt::Long;
use HTML::TreeBuilder;
use Data::Dumper;
use utf8;


my $URL =  'http://www.myp2p.eu/feeds/nowplaying.xml';

my $players = {
	'Sopcast'	=> ($ENV{'HOME'} ? $ENV{'HOME'}.'/sopcast-play.sh' : '~/sopcast-play.sh'),
	'Veetle'	=> '/usr/bin/google-chrome --kiosk',
	'MediaPlayer'	=> '/usr/bin/mplayer -fs'
};

my $mythtv_dir = $ENV{'HOME'} ? $ENV{'HOME'}.'/.mythtv' : undef;
my $sleep = 1;
my ($proxy, $quiet, $help);

GetOptions(
	'mythtv-dir:s'			=> \$mythtv_dir,
	'sopcast-player:s'		=> \$players->{Sopcast},
	'veetle-player:s'		=> \$players->{Vopcast},
	'media-player:s'		=> \$players->{MediaPlayer},
	'sleep:s'			=> \$sleep,
	'proxy:s'			=> \$proxy,
	'q|quiet'			=> \$quiet,
	'h|help'			=> \$help
);

if ($help) {
	print "myp2p.eu live rss feed parser which gets all playable links for the shows\n\n";
	print "Syntax: ".$0." [OPTION]... [URL]\n\n";
	print "if URL is not passed \"$URL\" will be used by default\n\n";
	print "Options:\n";
	print "       --mythtv-dir=DIR                   create XML code for MythTV menu and save it in this dir (myp2p_parser_*.xml). Default: $mythtv_dir\n\n";
	print "       Players for MythTv menu:\n";
	print "           --sopcast-player=COMMAND           open Sopcast streams (sop://) with this command. Default: ".$players->{Sopcast}."\n";
	print "           --veetle-player=COMMAND            open Veetle streams with this command. Default: ".$players->{Veetle}."\n";
	print "           --media-player=COMMAND             open MediaPlayer (mms://) streams with this command. Default: ".$players->{MediaPlayer}."\n\n";
	print "       --sleep=[SECONDS]                  how long to wait between downloading myp2p pages. Default is: $sleep\n";
	print "       --proxy=PROXY[:PORT]               proxy for downloading pages\n";
	print " -q,   --quiet                            do not output any info/debug messages\n";
	print " -h,   --help                             show this help\n\n";
	exit;
}



$URL = join('', @ARGV) if ($#ARGV >= 0);
debug("Using URL: $URL\n");

my $file = get_page($URL, 1);
$file =~s/&(?!amp;)/&amp;/gi;

# read rss file
my $xml = eval { XMLin($file) };
die('Invalid XML in RSS. Error: '.$@) if ($@);
my @items = @{$xml->{'channel'}->{'item'}};
my (@cats, %cats, @events);

foreach my $item (@items) {
	next if !$item->{link};

	debug("\nChecking link: ".$item->{link});

	sleep $sleep if $sleep;
	my $tb = get_tree($item->{link});
	next if !$tb;

	my @links; 
	foreach my $tr ($tb->look_down('_tag' => 'tr', sub { $_[0]->look_up('_tag', 'td', 'class' => 'itemlist_alt0') } )) {

		my @a = $tr->look_down('_tag' => 'a', 'href' => qr/^(sop|mms|https?):/);
		next if !@a;
		my @kbps = $tr->look_down('_tag' => 'td', sub { $_[0]->as_text() =~/kbps/i });

		my $link = {
			href => $a[0]->attr('href'),
			kbps => ( $kbps[0] && $kbps[0]->as_text() =~/(\d+)\skbps/i ? $1 : '???' )
		};

		# veetle is harder to find. check target links for veetle iframes
		if ($players->{Veetle} && $a[0]->attr('href') =~/^http:/ && (my @veetle = $tr->look_down('_tag' => 'td', sub { $_[0]->as_text() =~/Veetle/i }))) {
			$link->{type} = 'Veetle';

			my $vt = get_tree($link->{href});
			next if !$vt;
			$link->{href} =  undef;

			# embeded veetle iframes found?			
			if (my @viframe = $vt->look_down('_tag' => 'iframe', 'src' => qr/veetle.com\/index.php\/widget/)) {
				$link->{href} = $viframe[0]->attr('src');

			# try alternatives: check all iframes and try one more level
			} else {
				foreach my $if ($vt->look_down('_tag' => 'iframe', 'src' => qr/^https?:/)) {
					# ignore facebook or twitter frames
					next if $if->attr('src') =~/^https?:\/\/(www\.)?((facebook|twitter)\.(com|net))/i;

					my $vtt = get_tree($if->attr('src'));
					next if !$vtt;

					if (my @viframe = $vtt->look_down('_tag' => 'iframe', 'src' => qr/veetle.com\/index.php\/widget/)) {
						$link->{href} = $viframe[0]->attr('src');
						last;
					}
				}
			}

		} elsif ($players->{Sopcast} && $a[0]->attr('href') =~/^sop:/) {
			$link->{type} = 'Sopcast';
		} elsif ($players->{MediaPlayer} && $a[0]->attr('href') =~/^mms:/) {
			$link->{type} = 'MediaPlayer';
		} else {
			next;
		}

		if ($link->{href}) {
			$link->{player} = $players->{$link->{type}};
			push @links, $link if ! grep { $link->{href} eq $_->{href} } @links;
		}
	}

	if (@links) {
		@links = sort { $b->{kbps} <=> $a->{kbps} } @links;
	
		my $cat = $item->{title};
		if ($item->{title} =~/^\[(\w+)\]\s+(.*)$/) {
			$cat = $1;
			$item->{title} = $2;
		}
		if (!$cats{$cat}) {
			my @c;
			$cats{$cat} = {
				'title' => $cat,
				'events' => \@c
			};
			push @cats, $cats{$cat};
		}
		push @{$cats{$cat}->{events}}, {
			'title' => $item->{title},
			'links' => \@links
		};
	}
}

# create mythtv menus
if (@cats && $mythtv_dir && -d $mythtv_dir) {
	# every xml file begins with this name
	my $mythtv_xml_file = "myp2p_parser_";

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
				<text>$cat->{title}</text>
				<action>MENU $mythtv_catmenu</action>
			</button>
		);
	}
	print MYTHTV_MENU qq(</mythmenu>);
	close MYTHTV_MENU;
	debug("Created $mythtv_menu");

} else {
	# just print it out
	warn Dumper @cats;
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
	return $reqresponse->content;
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
