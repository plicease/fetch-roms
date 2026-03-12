#!/usr/bin/env perl

use 5.040;
use strict;
use warnings;
use URI;
use LWP::UserAgent;
use Mojo::DOM58;
use Path::Tiny ();
use Digest::SHA1;
use Storable ();

Fetch->instance->fetch;

package Fetch;

use List::Util qw( shuffle );

use Class::Tiny {
    systems => \&_build_systems,
    ua => sub { LWP::UserAgent->new },
};

sub instance {
    state $self;
    $self //= __PACKAGE__->new;
}

sub _build_systems ($self) {
    my @systems;
    return [@ARGV] if @ARGV;
    my $url = "https://edgeemu.net/";
    say "GET SYSTEM INDEX $url";
    my $res = $self->get($url);
    my $dom = Mojo::DOM58->new($res->decoded_content);
    my %systems;
    foreach my $a ($dom->find('option')->each) {
        my $id = $a->attr('value');
        next unless defined $id;
        next if $id eq 'all';
        $systems{$id}++;
    }
    return [shuffle keys %systems];

}

sub get ($self, $url) {
    if(my $cached = DB->instance->fetch_http_response($url)) {
        return $cached;
    }
    my $res = $self->ua->get($url);
    DB->instance->store_http_response($url, $res);
    return $res;
}

sub fetch ($self) {
    my @letters = qw( 1 a b c d e f g h i j k l m n o p q r s t u v w x y z );
    foreach my $system ($self->systems->@*) {
        foreach my $letter (shuffle @letters) {
            foreach my $file ($self->fetch_index($system, $letter)->@*) {
                next if $file->is_downloaded;
                $file->fetch;
            }
        }
    }
}

sub fetch_index ($self, $system, $letter) {
    my $url = URI->new("https://edgeemu.net/browse/$system/$letter");
    say "GET LETTER INDEX $url";
    my $res = $self->get($url);

    unless($res->is_success) {
        warn $res->status_line;
        return [];
    }

    my $dom = Mojo::DOM58->new($res->decoded_content);

    my @index;

    foreach my $e (shuffle $dom->find('details a')->each) {
        push @index, File->new(
            ua => $self->ua,
            url => URI->new_abs($e->attr('href'), $url),
            system => $system,
        );
    }

    return \@index;
}

package File;

use Class::Tiny {
    url    => sub { die "url is required"    },
    system => sub { die "system is required" },
    db     => sub { DB->instance },
    path   => \&_build_path,
};

sub _build_path ($self) {
    my @seg = $self->url->path_segments;
    Path::Tiny->new('new', $self->system, $seg[-1]);
}

sub fetch ($self) {
    say "GET @{[ $self->path ]}";

    unless($self->path->basename =~ /\.(zip|chd|rvz)\z/) {
        warn "do not know how to handle extension";
        return;
    }
    
    my $res = Fetch->instance->get($self->url);

    unless($res->is_success) {
        warn $res->status_line;
        return;
    }

    my $content = $res->decoded_content;

    $self->munge(\$content);

    $self->path->parent->mkpath;
    $self->path->spew_raw($content);
    $self->db->save_details($self);

    return;
}

sub munge ($self, $content) {
    if($self->path->basename =~ /\.zip\z/) {

        state $not_simple_zips = {
            'atari-st'         => 1,
            'commodore-amiga'  => 1,
        };

        if(!$not_simple_zips->{$self->system}) {
            require Archive::Libarchive::Peek;
            my $peek = Archive::Libarchive::Peek->new( memory => $content );
            if($peek->files == 1) {
                my $bad = 0;
                $peek->iterate(sub ($new_filename, $new_content, $e) {
                    if($new_filename =~ /\//) {
                        warn "$new_filename contains a slash" if $new_filename =~ /\//;
                        $bad = 1;
                        return;
                    }
                    $self->path($self->path->sibling($new_filename));
                    $$content = $new_content;
                });
                return if $bad;
            } else {
                warn "archive does not contain exactly one file: @{[ $peek->files ]}";
                return;
            }
        }
    }
}

sub is_downloaded ($self) {
    $self->db->already_downloaded($self);
}

sub size ($self) {
    die "file does not exist" unless -f $self->path;
    return -s $self->path;
}

sub sha1 ($self) {
    die "file does not exist" unless -f $self->path;
    my $sha1 = Digest::SHA1->new;
    $sha1->addfile($self->path->openr_raw);
    return $sha1->hexdigest;
}

package DB;

use Class::Tiny {
    dbh => \&_build_dbh,
};

sub instance {
    state $self;
    $self //= __PACKAGE__->new;
}

sub _build_dbh {
    require DBI;
    DBI->connect("dbi:SQLite:dbname=@{[ Path::Tiny->new(__FILE__)->sibling('.database') ]}",'','', { RaiseError => 1, AutoCommit => 1 });
}

sub BUILD ($self, $) {

    $self->dbh->do(q{
        CREATE TABLE IF NOT EXISTS file (
            id INTEGER PRIMARY KEY,
            url TEXT NOT NULL,
            path TEXT NOT NULL UNIQUE,
            sha1 TEXT,
            size INTEGER
        )
    });

    $self->dbh->do(q{
        CREATE TABLE IF NOT EXISTS cache (
            id INTEGER PRIMARY KEY,
            url TEXT NOT NULL UNIQUE,
            res BLOB NOT NULL,
            ts INTEGER NOT NULL
        )
    });

    # delet everything older than four hours
    $self->dbh->do(q{
        DELETE FROM cache WHERE ts < ?
    }, {}, time-14400);
}

sub already_downloaded ($self, $file) {
    my $sth = $self->dbh->prepare(q{
        SELECT path FROM file WHERE url = ?
    });
    $sth->execute($file->url);
    my($path) = $sth->fetchrow_array;
    # TODO: also check size and checksum?
    return $path && -f $path;
}

sub save_details ($self, $file) {
    $self->dbh->do(q{
        INSERT INTO file (url, path, sha1, size) VALUES (?,?,?,?)
    }, {}, $file->url, $file->path, $file->sha1, $file->size );
    return;
}

sub fetch_http_response ($self, $url) {

    my $sth = $self->dbh->prepare(q{
        SELECT res FROM cache WHERE url = ?
    });

    $sth->execute($url);
    my($frozen) = $sth->fetchrow_array;

    return undef unless defined $frozen;

    my $res = Storable::thaw($frozen);

    return $res;
}

sub store_http_response ($self, $url, $res) {
    return unless $res->is_success;

    my($ct) = $res->headers->content_type;
    return unless $ct eq 'text/html';

    my $frozen = Storable::freeze($res);

    my $sth = $self->dbh->prepare(q{
        INSERT INTO cache (url, res, ts) VALUES (?,?,?)
    });

    $sth->bind_param(1, $url);
    $sth->bind_param(2, $frozen, DBI::SQL_BLOB());
    $sth->bind_param(3, time);

    $sth->execute;

    return;
}
