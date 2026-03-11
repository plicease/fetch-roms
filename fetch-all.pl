#!/usr/bin/env perl

use strict;
use warnings;
use Path::Tiny qw( path );
use LWP::UserAgent;
use Mojo::DOM58;
use URI;
use HTML::Entities qw( decode_entities );
use Archive::Libarchive;
use Archive::Libarchive::Peek;
use List::Util qw( shuffle );
use feature qw( say signatures );

my $ua = LWP::UserAgent->new;

my @systems;

if(@ARGV) {
  @systems = @ARGV;
} else {
  @systems = get_systems();
}

my @letters = qw( 1 a b c de f g h i j k l m n o p q r s t u v w x y z );

my $base = URI->new("https://edgeemu.net");

foreach my $system (@systems)
{
  foreach my $letter (shuffle @letters)
  {
    my $index_uri = $base->clone;
    $index_uri->path(sprintf "/browse/%s/%s", $system, $letter );
    say "GET LETTER INDEX $index_uri";
    my $index_res = $ua->get($index_uri);
    if($index_res->is_success)
    {
      my $dom = Mojo::DOM58->new($index_res->decoded_content);
      x: foreach my $e (shuffle $dom->find('details a')->each)
      {
        my $game_url  = URI->new_abs($e->attr('href'), $index_res->base);
        $DB::single = 1;
        my $name = $e->content;

        my $guess_base = path("new/$system/@{[ decode_entities $name ]}");
        foreach my $ext (qw( .zip .chd .rvz )) {
          my $guess = $guess_base->sibling($guess_base->basename . $ext);
          next x if -f $guess;
        }
        
        say "GET GAME   DL    $game_url ($name)";
        my $game_res = $ua->get($game_url);
        if($game_res->is_success)
        {
          $guess_base->parent->mkpath;
          if($game_res->filename =~ /(\.(?:chd|rvz))$/) {
            my $name = $guess_base->sibling( $guess_base->basename . $1 );
            $name->spew_raw($game_res->decoded_content);
            say "                 $name";
          }
          else
          {
            local $@;
            eval {
              my $name = $guess_base->sibling( $guess_base->basename . ".zip" );
              my $w = Archive::Libarchive::ArchiveWrite->new;
              $w->set_format_zip;
              $w->open_filename("$name");
              Archive::Libarchive::Peek->new( memory => \$game_res->decoded_content )->iterate(sub ($filename, $content, $e) {
                say "                 $name/$filename";
                $w->write_header($e);
                $w->write_data(\$content);
              });
              $w->close;
            };
            if(my $error = $@) {
              warn "error extracting archive: $error";
              warn $game_res->filename;
              die;
            }
          }
        }
        else {
          warn $game_res->status_line;
        }
      }
    }
    else
    {
      warn $index_res->status_line
    }
  }
}


sub get_systems
{
  my $url = "https://edgeemu.net/";
  say "GET SYSTEM INDEX $url";
  my $res = $ua->get($url);
  my $dom = Mojo::DOM58->new($res->decoded_content);
  my %systems;
  foreach my $a ($dom->find('option')->each)
  {
    my $id = $a->attr('value');
    next unless defined $id;
    next if $id eq 'all';
    $systems{$id}++;
  }
  return shuffle keys %systems;
}
