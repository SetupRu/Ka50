package Ka50;

use 5.010;
use strict;
#use warnings;
#no warnings 'uninitialized';
no warnings;
use Carp;

use base 'Exporter';
our @EXPORT = our @EXPORT_OK = qw(http_request raw_connect form_request rps con detect);

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
use Web::Scraper; # for form fill
use URI::Escape::XS qw(uri_escape uri_unescape);


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
		'user-agent' => 'Ka/50',
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
					$s{reader} = sub {
						local *__ANON__ = '*read.watcher' if DEBUG;
						$s{fh} and $cb or return %s = ();
						#warn "ready to read @{[ %s ]}";
						while ( $s{fh} and ( $len = sysread $s{fh}, $rbuf, 64*1024, $roff ) ) {
							#warn "read $len";
							$roff += $len;
						}
						#warn "read ($!) $len <".$rbuf.'> '.$headers;
						if (!defined $headers and length $rbuf) {
							#return unless length $rbuf; # BULLSHIT!!!
							warn $rbuf if DEBUG > 1;
							my($ret, $minor_version, $status, $message, $aheaders) = 
								HTTP::Parser::XS::parse_http_response($rbuf, HTTP::Parser::XS::HEADERS_AS_ARRAYREF);
							if ($ret == -1 ){
								warn "need more ";#.dumper $rbuf;
								return;
							}
							elsif($ret == -2) {
								#return warn "need more ".dumper $rbuf if length $rbuf < 512;
								return warn "need more $rbuf" if length $rbuf < 100;
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
								#warn "buf ".length($rbuf)." lower than required ".($hlength + $clength)." <$rbuf> ".($len == 0 ? "EOF" : "");#.dumper $rbuf;
								return $e->("Short read") if defined $len and $len == 0;
								#return $cb->( substr($rbuf,$hlength), $headers, %s = () );
							} else {
								#warn "ok";
								return $cb->( substr($rbuf,$hlength,$clength,0), $headers, %s = (), "Content-Length" );
							}
						}
						#warn "how we get here (@{[ %s ]})?";
						if (defined $len) {
							#warn "EOF";
							if ($headers) {
								return $cb->( substr($rbuf,$hlength), $headers, %s = (), "EOF", );
							} else {
								return $e->("EOF Before read headers");
							}
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
					$s{rw} = AE::io $s{fh},0,$s{reader};
					$s{reader}();
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


sub find_and_fill {
	my $body = shift;
	my %fill = %{shift()};
	utf8::decode $body;
		my $sc = scraper {
			process 'form', 'form[]' => scraper {
				process 'form', action => '@action', method => '@method';
				process 'input', 'input[]' => scraper {
					process 'input', type => '@type', name => '@name' , value => '@value';
				};
			};
		};
		my $forms = $sc->scrape($body)->{form};
		my $form = $forms->[0];
		my @fill;
		if ($form) {
			for my $i ( @{$form->{input}} ) {
				if (exists $fill{$i->{name}}) {
					push @fill, $i->{name}, delete $fill{$i->{name}};
				}
				elsif ( $i->{type} =~ /^hidden$/i or ( $i->{type} =~ /submit/ and defined $i->{name} ) or ( $i->{type} =~ /checkbox/ and defined( $i->{value} //= 'on' ) ) ) {
					push @fill, $i->{name}, $i->{value};
				}
				else {
					#warn "skip ".dumper $i;
				}
			}
		} else {
			return undef, "No form found";
		}
		if (%fill) {
			return undef, "Left unfilled keys: ".join(', ',keys %fill);
		}
		#warn dumper {@fill};
		my $query = '';
		while(@fill) {
			my ($k,$v) = splice @fill,0,2;
			$query .= uri_escape($k).'='.uri_escape($v).'&';
		}
	return {
		action => $form->{action} || '',
		query  => $query,
		ctype  => 'application/x-www-form-urlencoded; charset=utf-8',
		method => uc( $form->{method} || 'POST' ),
	};
}

sub form_request {
	my $url = shift;
	my $cb = pop;
	my %args = @_;
	my %s;$s{_} = \%s;
	$s{r1} = http_request GET => $url, headers => $args{headers} || {},
	sub {
		my ($b,$h) = @_;
		if ($h->{Status} != 200) {
			return $cb->(undef, "$h->{Status} $h->{Reason}", %s = ());
		}
		my ($form,$error) = find_and_fill($b,delete $args{fill});
		return $cb->(undef, $error, %s = ()) unless $form;
		my $uri = URI->new( $h->{URL} );
		$uri->path( $form->{action} ) if $form->{action};
		http_request
			$form->{method} => "$uri",
			headers => { 'content-type' => $form->{ctype}, %{ $args{headers} || {} } },
			body => $form->{query},
			sub {
				my ($b,$h) = @_;
				if ($h->{Status} == $args{success}) {
					#warn dumper $h->{'set-cookie'};
					use HTTP::Easy::Cookies;
					my $c = HTTP::Easy::Cookies->decode( $h->{'set-cookie'} );
					#warn dumper $c;
					my @cookies = map {
						my @list;
						for my $k (keys %$_) { push @list, qq{$k=}.uri_escape($_->{$k}{value}); }
						@list
					} map { ref() ? ( values %$_ ) : () } values %$c;
					my $cookie = join '; ',@cookies;
					$cb->( { cookie => $cookie }, %s = () );
				} else {
					return $cb->(undef, "$h->{Status} $h->{Reason}", %s = ());
				}
			};
		#
	};
	return;
}

# Loaders

sub rps1 (&@) {
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
	return defined wantarray ?
		guard { %s = (); } : undef;
}

sub rps (&@) {
	my $code = shift;
	my %args = @_;
	my $t = 1/$args{rps};
	my ($N,$f);
	if (exists $args{f}) {
		$f = $args{f};
		$N = int($f/$t);
	} else {
		$N = $args{n} or die "Requred f or n\n";
		$f = $N/$args{rps};
	}
	my %s;$s{s} = \%s;
	AE::now_update();
	say "start RPS, n=$N, f=$f, t=$t ".sprintf(" N=%f",$f/$t);
	$s{t} = AE::timer $t,$t,$code;
	$s{e} = AE::timer $f, 0, sub {
		say "Finished after $f";
		$args{e} and $args{e}();
		%args = %s = ();
	};
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
	my %args = (@_);
	my $prec = $args{precision} // 0.1;
	my $must = $args{must} // 0.9;
	my $reset = $args{reset} // 0.5;
	my $lastrun = 0;
	my $collected;
	my $continue = 1;
	my $avg;
	my $sum = 0;
	 my $collecting; my $hit = 0; my $miss = 0; my $match = 0;
	my $i = 0; my $offs = $args{n};
	my $cv = AE::cv {
		$args{e} and $args{e}($lastrun, $avg, $sum, $i);
	};
	$cv->begin;
	con {
		my $next = shift;
		my $start = time;
		
		$code->(sub {
			$continue = shift if @_;
			my $run = time - $start;
			$i++;
			return $next->(1) if $i <= $args{n}; # Skip first N requests to give a warm
			$sum += $run;
			$avg = $sum/($i - $offs);
			#warn "det: 1st run: $run";
			printf "\r%d requested avg=%0.6f, last=%0.6f match=%0.2f%% (%d+%d) ...",$i, $avg, $run, $match * 100, $hit,$miss;
				
			if( $run > $avg * ( 1 + $reset ) ) { # if some call goes over average over 50%, reset counters
				#say "$hit/$miss $run / $avg";
				$hit = $miss = $match = 0;
				$offs = $i;
				$sum = 0;
			}
			else {
				if ($run < $avg *( 1+$prec )) {
					$hit++;
				}
				else {
					$miss++;
				}
				$match = ($hit)/($hit+$miss);
				$continue = 0 if $match > $must and $i - $offs > $args{n};
			}
			$next->($continue);
			$lastrun = $run;
		});
	} c => $args{c}, e => sub {
		#warn "det: end";
		printf "\n%0.1f%% of last %d requests was less than average %06fs + %0.2d%%\n",$match*100, $args{n}, $avg, $prec*100;
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
