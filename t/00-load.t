#!/usr/bin/env perl -w

use common::sense;
use lib::abs '../lib';
use Test::More tests => 2;
use Test::NoWarnings;

BEGIN {
	use_ok( 'Ka50' );
}

diag( "Testing Ka50 $Ka50::VERSION, Perl $], $^X" );
