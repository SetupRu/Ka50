package Ka50;

use 5.010;
use strict;
#use warnings;
#no warnings 'uninitialized';
no warnings;
use Carp;

use base 'Exporter';
our @EXPORT = our @EXPORT_OK = qw(http_request raw_connect rps con detect);

=head1 NAME

Ka50 - ...

=cut

our $VERSION = '0.01'; $VERSION = eval($VERSION);

sub DEBUG () { 0 }
sub TRACE () { 0 }

=head1 SYNOPSIS

    package Sample;
    use Ka50;

    ...

=head1 DESCRIPTION

    ...

=cut

use HTTP::Parser::XS;
use AnyEvent::Socket;
use AnyEvent::CacheDNS ':register';
use Socket;

use Time::HiRes 'time';
use Guard 'guard';

sub raw_connect($$$;$) {
	my ($addr, $port, $connect, $prepare) = @_;
	length $addr == 4 or die "Please pass packed IPv4 address";
	my $sockaddr = sockaddr_in($port, $addr);
	
	my %state;
	socket $state{fh}, Socket::PF_INET, Socket::SOCK_STREAM(), Socket::IPPROTO_TCP
		or return $connect->(undef, "$!");
	AnyEvent::Util::fh_nonblocking $state{fh}, 1;
	if (
		(connect $state{fh}, $sockaddr)
		or (
			$! == Errno::EINPROGRESS # POSIX
			or $! == Errno::EWOULDBLOCK
			or $! == AnyEvent::Util::WSAEINVAL # not convinced, but doesn't hurt
			or $! == AnyEvent::Util::WSAEWOULDBLOCK
		)
	) {
		$state{ww} = AE::io $state{fh}, 1, sub {
			$state{fh} or return;
			#warn "ww / $state{fh}";
			if (my $sin = getpeername $state{fh}) {
				my ($port, $host) = Socket::unpack_sockaddr_in( $sin );
				delete $state{ww}; delete $state{to};
				$connect->(delete $state{fh},Socket::inet_ntoa( $host ), $port);
				%state = ();
			} else {
				if ($! == Errno::ENOTCONN) {
					sysread $state{fh}, my $buf, 1;
					$! = (unpack "l", getsockopt $state{fh}, Socket::SOL_SOCKET(), Socket::SO_ERROR()) || Errno::EAGAIN
						if AnyEvent::CYGWIN && $! == Errno::EAGAIN;
				}
				return if $! == Errno::EAGAIN;
				delete $state{ww}; delete $state{to};
				%state = ();
				$connect->();
			}
		};
	}
}


sub http_request {
	my $cb = pop;
	my $method = uc shift;
	my $url = shift;
	my (%args) = (timeout => 30, @_);
	my ($uscheme, $uauthority, $upath, $query, undef) = # ignore fragment
		$url =~ m|^([^:]+):(?://([^/?#]*))?([^?#]*)(?:(\?[^#]*))?(?:#(.*))?$|;
	$uauthority =~ /^(?: .*\@ )? ([^\@:]+) (?: : (\d+) )?$/x
		or return $cb->(undef, { Status => 599, Reason => "Unparsable URL" });
	my $host = lc $1;
	my $port = defined $2 ? $2 : do {
		$uscheme eq "http"  ?  80 :
		$uscheme eq "https" ? 443 :
		return $cb->(undef, { Status => 599, Reason => "Only http and https URL schemes supported" });
	};
	$upath .= $query if length $query;
	$upath =~ s%^/?%/%;
	
	my %s; $s{_} = \%s;
	my $s = \%s;
	my %hdr = (
		Host       => $host,
		connection => 'close',
	);
	$hdr{"content-length"} = length $args{body} if length $args{body} or $method ne "GET";
	if (my $hdr = $args{headers}) {
		while (my ($k, $v) = each %$hdr) {
			$hdr{lc $k} = $v;
		}
	}
	
	my $e = sub {
		local *__ANON__ = '*errorhandler' if DEBUG;
		%s = ();
		$cb->(undef,{URL => $url, Status => 599, Reason => $_[0]});
		$cb = sub {
			local *__ANON__ = '*cb.destroyed' if DEBUG;
			Carp::cluck "called cb again from @{[ (caller)[1,2] ]} / @{[ %s ]}";
		} if 0;
		undef $cb;
	};
	$s{to} = AE::timer $args{timeout},0,sub {
		local *__ANON__ = '*timeout.watcher' if DEBUG;
		#Carp::cluck "timeout fired";
		$! = (unpack "l", getsockopt $s{fh}, Socket::SOL_SOCKET(), Socket::SO_ERROR()) || Errno::ETIMEDOUT;
		%s = ();
		$e->("Request timed out ($!)");
	} if $args{timeout};
	warn "resolving $host" if TRACE;
	AnyEvent::DNS::a $host, sub {
		local *__ANON__ = '*resolve.handler' if DEBUG;
		my @addrs = @_
			or return $e->("Resolve '$host' failed: $!");
		warn "connecting $host/@addrs" if TRACE;
		socket $s{fh}, Socket::PF_INET, Socket::SOCK_STREAM(), Socket::IPPROTO_TCP
			or return $e->("$!");
		AnyEvent::Util::fh_nonblocking $s{fh}, 1;
		binmode $s{fh}, ':raw';
		my $sockaddr = sockaddr_in($port, Socket::inet_aton($addrs[0]));
		if (
			(connect $s{fh}, $sockaddr)
			or (
				   $! == Errno::EINPROGRESS # POSIX
				or $! == Errno::EWOULDBLOCK
				or $! == AnyEvent::Util::WSAEINVAL # not convinced, but doesn't hurt
				or $! == AnyEvent::Util::WSAEWOULDBLOCK
			)
		) {
			warn "connected $host/$addrs[0] ($!)" if TRACE;
			my $wbuf = 
				"$method $upath HTTP/1.0\015\012"
				. (join "", map "\u$_: $hdr{$_}\015\012", grep defined $hdr{$_}, keys %hdr)
				. "\015\012"
				. (delete $args{body});
			warn $wbuf if DEBUG > 1;
			my $wlen = length $wbuf;
			my $woff = 0;
			$s{ww} = AE::io $s{fh}, 1, sub {
				local *__ANON__ = '*write.watcher' if DEBUG;
				$s{fh} and $cb or return %s = ();
				if (my $wrl = syswrite($s{fh},$wbuf, $wlen, $woff)) {
					#warn "written $wrl";
					warn "written $wrl ($!)" if TRACE;
					if ($wrl < $wlen) {
						warn "written $wrl of $wlen ($!)" if TRACE;
						$woff += $wrl;
						$wlen -= $wrl;
						return;
					}
					delete $s{ww};
					my $rbuf = '';
					my $roff = 0;
					my $len;
					my $hlength;
					my $clength;
					my $headers;
					$s{rw} = AE::io $s{fh},0,sub {
						local *__ANON__ = '*read.watcher' if DEBUG;
						#warn "ready to read @{[ %s ]}";
						$s{fh} and $cb or return %s = ();
						while ( $s{fh} and ( $len = sysread $s{fh}, $rbuf, 64*1024, $roff ) ) {
							#warn "read $len";
							$roff += $len;
						}
						#warn "read $len";
						if (!defined $headers) {
							my($ret, $minor_version, $status, $message, $aheaders) = 
								HTTP::Parser::XS::parse_http_response($rbuf, HTTP::Parser::XS::HEADERS_AS_ARRAYREF);
							if ($ret == -1 ){
								warn "need more ";#.dumper $rbuf;
								return;
							}
							elsif($ret == -2) {
								#return warn "need more ".dumper $rbuf if length $rbuf < 512;
								return warn "need more " if length $rbuf < 512;
								return $e->("Garbled response headers");
							}
							else {
								my %hdr = ( @$aheaders, Status => $status, Reason => $message, URL => $url );
								$hlength = $ret;
								$headers = \%hdr;
								$clength = $hdr{'content-length'};
							}
						}
						if (defined $clength) {
							if (length $rbuf < $hlength + $clength) {
								warn "buf ".length($rbuf)." lower than required ".($hlength + $clength);#.dumper $rbuf;
								return $e->("Short read") if $len == 0;
								#return $cb->( substr($rbuf,$hlength), $headers, %s = () );
							} else {
								#warn "ok";
								return $cb->( substr($rbuf,$hlength,$clength,0), $headers, %s = (), "Content-Length" );
							}
						}
						#warn "how we get here (@{[ %s ]})?";
						if (defined $len) {
							#warn "EOF";
							return $cb->( substr($rbuf,$hlength), $headers, %s = (), "EOF", );
						}
						else {
							if ($! == Errno::EAGAIN or $! == Errno::EINTR or $! == AnyEvent::Util::WSAEWOULDBLOCK) {
								#warn "$! ()";
								return;
							} else {
								return $e->("$!");
							}
						}
						die "Unreach";
					};
				} else {
					if ($! == Errno::ENOTCONN or $! == Errno::EAGAIN or $! == Errno::EINTR or $! == AnyEvent::Util::WSAEWOULDBLOCK) {
						return;
					} else {
						return $e->("$!");
					}
				}
			};
			return;
		} else {
			return $e->("$!");
		}
	};
	return;
}

# Loaders

sub rps (&@) {
	my $code = shift;
	my %args = @_;
	use uni::perl ':dumper';
	warn dumper \%args;
	my $t = 1/$args{rps};
	my ($N,$f);
	if (exists $args{f}) {
		$f = $args{f};
		$N = int($f/$t);
	} else {
		$N = $args{n} or die "Requred f or n\n";
	}
	my %s;$s{s} = \%s;
	my $start = my $last = time;
	my $gap = my $c = 0;
	$s{i} = AE::idle sub {
		my $d = -$last + (time);
		printf "\rdelta = %f, eff rps = %06.1f",$d, 1/$d;
		if ($d > $t) {
			$last = time;
			$code->();
			if (++$c >= $N) {
				printf "N = %d, total run = %f (gap ticks=%d)\n", $N, $last - $start, $gap;
				$args{e} and $args{e}();
				%args = %s = ();
			};
		} else {
			$gap++;
		}
		#%s = ();
		return;
	};
	warn "created watcher";
	return defined wantarray ?
		guard { %s = (); } : undef;
}

sub con (&@) {
	my $code = shift;
	my %args = @_;
	my $c = $args{c} or die "Need concurrency var";
	my $N = $args{n};
	my $unlimited = ($N <= 0);
	my @pt;
	say "Starting with ".($unlimited ? "unlimited" : $N)."/$c";
	my $cv = AE::cv {
		$args{e} and $args{e}();
	};
	
	$N--;
	my $start = time;
	my $run = $c;
	$code->(sub {
		my $sin = time - $start;
		my $wait = ( $c > 1 ) ? ( $sin/($c-1) ) : 0;
		#warn "1st run=$sin, N = $N, wait = $wait, start $run threads";
		AE::now_update;
		my $t;$t = AE::timer 0, $wait, sub {
			#warn "call timer $c";
			if ($c > 0) {
				my $thr = $c;
				$c--;
				#warn "T$thr.start (left $c)";
				$cv->begin;
				my $go;$go = sub {
					my $continue = $unlimited ? shift : $N-- > 0;
					if (!$continue) {
						#warn "T$thr.end (left: $cv->{_ae_counter})";
						$cv->end;
						$go = sub { warn "call of go after end" };
						return;
					} else {
						#warn "T$thr.next(@_)";
						$code->($go);
					}
				};
				$go->($unlimited ? 1 : ());
				undef $t if $c == 0;
			} else {
				undef $t;
			}
			return;
		};
	});
	return;
}

sub detect(&%) {
	my $code = shift;
	my %args = @_;
	my $cv = AE::cv {
		$args{e} and $args{e}();
	};
	$cv->begin;
	my $lastrun = 0;
	my $collected;
	my $continue = 1;
	con {
		my $next = shift;
		my $start = time;
		$code->(sub {
			my $run = time - $start;
			#warn "det: 1st run: $run";
			if ($run > $lastrun) {
				#warn sprintf "time grows (+%f), go ($continue)", $run - $lastrun;
				$lastrun = $run;
				$collected = 0;
				$next->($continue);
			} else {
				#warn sprintf "time less (%f), collect", $run - $lastrun;
				if (++$collected > $args{n}) {
					$next->($continue = 0);
				} else {
					$next->($continue);
				}
			}
		});
	} c => $args{c}, e => sub {
		#warn "det: end";
		$cv->end;
	};
	return;
}

=head1 AUTHOR

Mons Anderson, C<< <mons@cpan.org> >>

=head1 COPYRIGHT & LICENSE

Copyright 2012 Mons Anderson, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

=cut

1;
