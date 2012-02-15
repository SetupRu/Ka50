package Ka50::Draw;

use 5.010;
use strict;
use base 'Exporter';
our @EXPORT = our @EXPORT_OK = qw(draw);

use List::Util qw(min max);
use Imager;

our %COLOR = (
	100 => '#aaaaaa',#'Continue',
	101 => '#bbbbbb',# 'Switching Protocols',
	102 => '#cccccc',#,'Processing',                      # RFC 2518 (WebDAV)

	200 => '#55FF55',#'OK',
	201 => '#77EE77',#'Created',
	202 => '#77EE77',#'Accepted',
	203 => '#77EE77',#'Non-Authoritative Information',
	204 => '#77EE77',#'No Content',
	205 => '#77EE77',#'Reset Content',
	206 => '#77EE77',#'Partial Content',
	207 => '#77EE77',#'Multi-Status',                    # RFC 2518 (WebDAV)

	300 => '#EEEE77',#'Multiple Choices',
	301 => '#aaaaff',#'Moved Permanently',
	302 => '#aaaaff',#'Found',
	303 => '#EEEE77',#'See Other',
	304 => '#EEEE77',#'Not Modified',
	305 => '#EEEE77',#'Use Proxy',
	307 => '#EEEE77',#'Temporary Redirect',

	400 => '#FF0000',#'Bad Request',
	401 => '#ffaaaa',#'Unauthorized',
	402 => '#ffaaaa',#'Payment Required',
	403 => '#FF7777',#'Forbidden',
	404 => '#FF9999',#'Not Found',
	405 => '#ff0000',#'Method Not Allowed',
	406 => '#ffaaaa',#'Not Acceptable',
	407 => '#ffaaaa',#'Proxy Authentication Required',
	408 => '#ff0000',#'Request Timeout',
	409 => '#ffaaaa',#'Conflict',
	410 => '#ffaaaa',#'Gone',
	411 => '#ff0000',#'Length Required',
	412 => '#ffaaaa',#'Precondition Failed',
	413 => '#ff3333',#'Request Entity Too Large',
	414 => '#ff0000',#'Request-URI Too Large',
	415 => '#ffaaaa',#'Unsupported Media Type',
	416 => '#ff0000',#'Request Range Not Satisfiable',
	417 => '#ffaaaa',#'Expectation Failed',
	422 => '#ffaaaa',#'Unprocessable Entity',            # RFC 2518 (WebDAV)
	423 => '#ffaaaa',#'Locked',                          # RFC 2518 (WebDAV)
	424 => '#ffaaaa',#'Failed Dependency',               # RFC 2518 (WebDAV)
	425 => '#ffaaaa',#'No code',                         # WebDAV Advanced Collections
	426 => '#ffaaaa',#'Upgrade Required',                # RFC 2817
	449 => '#ffaaaa',#'Retry with',                      # unofficial Microsoft
);

=for rem

	500 => 'Internal Server Error',
	501 => 'Not Implemented',
	502 => 'Bad Gateway',
	503 => 'Service Unavailable',
	504 => 'Gateway Timeout',
	505 => 'HTTP Version Not Supported',
	506 => 'Variant Also Negotiates',         # RFC 2295
	507 => 'Insufficient Storage',            # RFC 2518 (WebDAV)
	509 => 'Bandwidth Limit Exceeded',        # unofficial
	510 => 'Not Extended',                    # RFC 2774

	599 => 'Client Error',
=cut

sub draw {
	my $file = !ref $_[0] ? shift : "sample.png";
	my @c = @_;
	my $h = @c;
	my $w = 0;
	my $wF = 1;
	my ($min,$max,$avg) = (0xFFFFFFFF,0,0);
	for my $r (@c) {
		unless (ref $r eq 'ARRAY') {
			if ($r) {
				warn dumper $r;
				exit;
			}
			next;
		};
		my @r = @$r;
		my $st = $r[1];
		my $ln = $r[2];
		#warn "$st -> $ln";
		$min = min($ln,$min);
		$max = max($ln,$max);
		$avg += $ln;
		
		$w = max($w, $st + $ln);
		$r->[3] = {
			color => $COLOR{$r[0]} // 'red',
			st => $st,
			en => $st + $ln,
		};
	}
	$avg /= @c;
	printf "Total runtime: %0.6fs\n", $c[-1][1] + $c[-1][2];
	printf "Avg Rps: %0.3f/s\n", @c/( $c[-1][1] + $c[-1][2] );
	printf "Min time: %0.6fs\n", $min;
	printf "Max time: %0.6fs\n", $max;
	printf "Avg time: %0.6fs\n", $avg;
	my $desired = 1200;
	if ($w < $desired) {
		$wF = $desired / $w;
	}
	elsif ($w > $desired) {
		$wF = $w / $desired;
	}
	$w = int( $w * $wF );
	#printf "creating image %d x %d (wF=%f)\n",$w,$h,$wF;
	my $xof = 25;
	my $yof = 25;
	my $vg = 25; # vert grid
	my $i = Imager->new( xsize => $w+$xof+1, ysize => $h+$yof+1, color => 'white' )
		or warn Imager->errstr;
	if ($i) {
		$i->flood_fill(x => 1, y => 1, color => 'white');
		$i->box( color => 'black', xmin => $xof-1, ymin => $yof-1, filled => 0,  );
		for (0..$h/$vg) {
			$i->line( color => 'black',
				x1 => $xof-( $_ % 2 ? '5' : $_ % 4 ? '10' : '15' ), x2 => $xof - 1,
				y1 => $yof + ($_ * $vg), y2 => $yof + ($_ * $vg),
			);
			$i->line( color => '#eeeeee',
				x1 => $xof + 1, x2 => $w + $xof,
				y1 => $yof + ($_ * $vg), y2 => $yof + ($_ * $vg),
			);
		}
		my $tl = 0;my $ag = 0.1;
		while ( $tl * $ag * $wF < $w ) {
			$i->line( color => 'black',
				x1 => $xof + int ($tl * $ag * $wF), x2 => $xof + int($tl * $ag * $wF),
				y1 => $yof-( 4 ), y2 => $yof - 1,
			);
			$i->line( color => '#eeeeee',
				x1 => $xof + int ($tl * $ag * $wF), x2 => $xof + int ($tl * $ag * $wF),
				y1 => $yof + 1, y2 => $h+$yof,
			);
			$tl++;
		}
		$tl = 0; $ag = 0.5;
		while ( $tl * $ag * $wF < $w ) {
			$i->line( color => 'black',
				x1 => $xof + int ($tl * $ag * $wF), x2 => $xof + int($tl * $ag * $wF),
				y1 => $yof-( 7 ), y2 => $yof - 1,
			);
			$tl++;
		}
		$tl = 0; $ag = 1;
		while ( $tl * $ag * $wF < $w ) {
			$i->line( color => 'black',
				x1 => $xof + int ($tl * $ag * $wF), x2 => $xof + int($tl * $ag * $wF),
				y1 => $yof-( 15 ), y2 => $yof - 1,
			);
			$tl++;
		}
		for my $y (0..$#c) {
			my $p = $c[$y][3];
			#warn "write $y: $p->{st} -> $p->{en} ($p->{color})";
			$i->line( color => $p->{color}, x1 => $xof + int( $p->{st}*$wF ), x2 => $xof + int( $p->{en} * $wF ), y1 => $yof + $y, y2 => $yof + $y );
		}
		say "Saving graph in $file";
		$i->write( file => $file );
	}
}

1;
