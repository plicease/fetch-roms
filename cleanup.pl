#!/usr/bin/env perl

use strict;
use warnings;
use feature qw( signatures say );
use Path::Tiny;
use Archive::Libarchive::Peek;

my $bad   = 0;
my $total = 0;

Path::Tiny->new('roms')->visit(sub ($path, $) {

  return unless -f $path;
  return unless $path->basename =~ /\.zip$/;

  $total++;

  local $@;
  eval {
    foreach my $filename (Archive::Libarchive::Peek->new(filename => "$path")->files) {
      say "$path/$filename";
    }
  };
  if($@) {
    $bad++;
    unlink $path;
  };

}, { recurse => 1 });

say "bad: $bad/$total";
