#!/usr/bin/perl

#############################################################################
#  
# myp2p.eu live rss feed parser which gets all SOP links for the streams
# shows/events without sop links (sop://) will be excluded.
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

my $mythtv_action = "~/sopcast-play.sh";
my $mythtv_dir = $ENV{'HOME'} ? $ENV{'HOME'}.'/.mythtv' : undef;

my ($proxy, $help);
GetOptions(
	'proxy:s'			=> \$proxy,
	'mythtv-dir:s'			=> \$mythtv_dir,
	'mythtv-action:s'		=> \$mythtv_action,
	'h|help'			=> \$help
);

if ($help) {
	print "myp2p.eu live rss feed parser which gets all SOP links for all shows\n\n";
	print "Syntax: ".$0." [OPTION]... [URL]\n\n";
	print "Options:\n";
	print "       --proxy=PROXY[:PORT]               proxy for downloading pages\n";
	print "       --mythtv-dir=DIR                   create XML code for MythTV menu and save it in this dir (myp2p_parser_*.xml). Default: $mythtv_dir\n";
	print "       --mythtv-action=COMMAND            open streams with this command. Default: $mythtv_action\n";
	print " -h,   --help                             show this help\n\n";
	exit;
}

die('No feed url passed.') if $#ARGV < 0;

my $file = get_page(join '', @ARGV);
$file =~s/&(?!amp;)/&amp;/gi;

# read rss file
my $xml = eval { XMLin($file) };
die('Invalid XML in RSS. Error: '.$@) if ($@);
my @items = @{$xml->{'channel'}->{'item'}};
my @events;

foreach my $item (@items) {
	next if !$item->{link};
	my $html = get_page($item->{link});

	my $tb = HTML::TreeBuilder->new();
	$tb->parse($html) or die "cannot parse page content";
	$tb->eof;

	my @links; 
	foreach my $tr ($tb->look_down('_tag' => 'tr', sub { $_[0]->look_up('_tag', 'td', 'class' => 'itemlist_alt0') } )) {
		if ((my @a = $tr->look_down('_tag' => 'a', 'href' => qr/^sop:/)) && (my @kbps = $tr->look_down('_tag' => 'td', sub { $_[0]->as_text() =~/kbps/i })) != 0) {
			push @links, {
				'href' => $a[0]->attr('href'),
				'kbps' => ( $kbps[0]->as_text() =~/(\d+)\skbps/i ? $1 : 0 )
			} if ! grep { $a[0]->attr('href') eq $_->{href}} @links;
		}
	}

	if (@links) {
		@links = sort { $b->{kbps} <=> $a->{kbps} } @links;
		push @events, {
			'title' => $item->{title},
			'links' => \@links
		};
	}
}

if (@events && $mythtv_dir && -d $mythtv_dir && $mythtv_action && -e $mythtv_action) {
	# every xml file begins with this name
	my $mythtv_xml_file = "myp2p_parser_";

	# delete old existing xmls
	unlink glob("$mythtv_dir/$mythtv_xml_file*.xml");

	my $mythtv_menu = "$mythtv_dir/$mythtv_xml_file"."main.xml";
	open MYTHTV_MENU, '>', $mythtv_menu;
	print MYTHTV_MENU qq(<mythmenu name="MYP2P_MENU">);

	my $cnt = 0;
	foreach my $event (@events) {
		my $submenu = qq(<mythmenu name="MYP2P_MENU_).(++$cnt).qq(">);

		my $scnt = 0;
		foreach (@{$event->{'links'}}) {
			$submenu .= qq(
				<button>
					<type>VIDEO_BROWSER</type>
					<text>Link ).(++$scnt).qq(: $_->{'kbps'} kbps</text>
					<action>EXEC $mythtv_action $_->{'href'}</action>
				</button>
			);
		}
		$submenu .= qq(</mythmenu>);

		my $mythtv_submenu = $mythtv_xml_file.$cnt.".xml";
		open MYTHTV_SUBMENU, '>', "$mythtv_dir/$mythtv_submenu";
		print MYTHTV_SUBMENU $submenu."\n";
		close MYTHTV_SUBMENU;

		print MYTHTV_MENU qq(
			<button>
				<type>VIDEO_BROWSER</type>
				<text>$event->{title}</text>
				<action>MENU $mythtv_submenu</action>
			</button>
		);

	}
	print MYTHTV_MENU qq(</mythmenu>);
	close MYTHTV_MENU;
}

# just print it out
warn Dumper @events;

sub get_page {
	my $req = LWP::UserAgent->new();
        $req->proxy('http', $proxy) if $proxy ; 
	$req->timeout(30);
	$req->show_progress(1);
	my $reqresponse = $req->get(shift());
	die('Could not open url') if ($reqresponse->is_error);
	return $reqresponse->content;
}
