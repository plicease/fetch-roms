#!/usr/bin/env perl

use strict;
use warnings;
use 5.014;
use Path::Tiny qw( path );
use LWP::UserAgent;
use Mojo::DOM58;
use URI;
use HTML::Entities qw( decode_entities );

my $ua = LWP::UserAgent->new;

# coleco ?

my @systems = qw(

  nes
  atari5200
  snes
  gb
  gbc
  gba
  genesis
  sms
  fds

);

my @letters = qw( num A B C D E F G H I J K L M N O P Q R S T U V W X Y Z );

my $base = URI->new("https://edgeemu.net");

foreach my $system (@systems)
{
  foreach my $letter (@letters)
  {
    my $index_uri = $base->clone;
    $index_uri->path("/browse-$system-$letter.htm");
    say "GET LETTER INDEX $index_uri";
    my $index_res = $ua->get($index_uri);
    if($index_res->is_success)
    {
      my $dom = Mojo::DOM58->new($index_res->decoded_content);
      foreach my $e ($dom->find('#content table.roms tr td a')->each)
      {
        my $game_index_url  = URI->new_abs($e->attr('href'), $index_res->base);
        my $name = $e->content;

        my $guess_name = path("roms/$system/@{[ decode_entities $name ]}.zip");
        next if -e $guess_name;
        
        say "GET GAME   INDEX $game_index_url ($name)";
        my $game_index_res = $ua->get($game_index_url);
        if($game_index_res->is_success)
        {
          my $dom = Mojo::DOM58->new($game_index_res->decoded_content);
          my $count = 0;
          foreach my $e ($dom->find('#content table a')->each)
          {
            my $download_url = URI->new_abs($e->attr('href'), $game_index_res->base);
            my $name = $e->content;
            next if $name =~ /www\.adobe\.com/;
            say "GET GAME   DL    $download_url ($name)";

            my $download_res = $ua->get($download_url);
            my $filename = $download_res->filename;
            my $path = path("roms/$system/$filename");
            next if -e $path;
            $path->parent->mkpath;
            $path->spew_raw($download_res->decoded_content);
            $count++;
            last;
          }
        }
      }
    }
    else
    {
      die $index_res->status_line
    }
  }
}
