#!/usr/bin/env perl

use strict;
use warnings;
use Term::ANSIColor qw( :constants );
use File::Spec;
use File::Basename;

my $files_to_delete = {};
my @units = qw( B KB MB GB TB PB );
my @jpegs;
my @raws;

$Term::ANSIColor::AUTORESET = 1;

sub uniq {
    my %seen;
    grep !$seen{$_}++, @_;
}

sub read_answer {
    local $Term::ANSIColor::AUTORESET = 0;
    print BRIGHT_WHITE;
    my $answer = <STDIN>;
    chomp $answer;
    print RESET;
    return $answer;
}

sub define_extensions {
    my $jpegs = 'JPG jpg JPEG jpeg';
    my $raws  = 'RW2 CR2 DNG dng';

    print BOLD CYAN "What extensions do your sidecars have? ";
    print FAINT WHITE "[$jpegs] ";
    @jpegs = split(' ', read_answer || $jpegs);

    print BOLD CYAN "What extensions do your raw photos have? ";
    print FAINT WHITE "[$raws] ";
    @raws = split(' ', read_answer || $raws);

    print "\n";
}

sub traverse_tree {
    my ($dir) = @_;
    opendir(my $dh, $dir) || die "Can't open $dir: $!";
    print FAINT YELLOW "Scanning directory $dir\n";

    my $files = {};
    while (readdir $dh) {
        next if m/^\.+$/; # skip . and ..

        my $filename = $_;
        my $path = File::Spec->catfile($dir, $filename);

        if (-d $path) {
            traverse_tree($path);
        } else {
            next unless $filename =~ m/^(.*)\.([^.]+)$/;
            $files->{$1}{$2} = 1;
        }
    }

    closedir($dh);
    process_dir($dir, $files);
}


sub process_dir {
    my ($dir, $files) = @_;

    for my $name (keys %$files) {
        my $extensions = $files->{$name};
        my $file = undef;

        for my $ext (@jpegs) {
            if ($extensions->{$ext}) {
                delete $extensions->{$ext};
                $file = File::Spec->catfile($dir, "$name.$ext");
                last;
            }
        }

        next unless $file;

        for my $ext (keys %$extensions) {
            push @{ $files_to_delete->{$ext} }, $file;
        }
    }
}

sub prompt {
    if (!%$files_to_delete) {
        print BRIGHT_RED "\nNo sidecars found\n";
        exit;
    }

    print BOLD GREEN "\nFound sidecars of:\n";
    for my $ext (@raws) {
        next unless $files_to_delete->{$ext};
        print BOLD GREEN sprintf("- %d %s files\n", scalar @{ $files_to_delete->{$ext} }, $ext);
    }

    my $answer = 's';
    while ($answer eq 's') {
        print BOLD CYAN "\nWould you like to (d)elete them, (s)ee a list of directories, or (q)uit? ";
        print FAINT WHITE "[d/s/Q] ";

        $answer = lc(read_answer);
        print_directories() if $answer eq 's';
    }
    return $answer eq 'd';
}

sub print_directories {
    for my $ext (@raws) {
        next unless $files_to_delete->{$ext};
        print BOLD GREEN sprintf("\nFound sidecars of %s files in the following directories:\n", $ext);
        my $count = {};
        for my $dir (sort(uniq(map { $count->{dirname($_)}++; dirname($_) } @{ $files_to_delete->{$ext} }))) {
            print BOLD YELLOW sprintf("[%5d] %s\n", $count->{$dir}, $dir);
        }
    }
}

sub delete_files {
    my $total_size = 0;
    my $ext_size;
    for my $ext (@raws) {
        for my $file (@{ $files_to_delete->{$ext} }) {
            my $size = -s $file // 0;
            print MAGENTA sprintf("Deleting %s (%s), a sidecar of %s\n", $file, format_size($size), $ext);
            $total_size += $size;
            $ext_size->{$ext} += $size;
            unlink $file;
        }
    }
    print_report($total_size, $ext_size);
}

sub print_report {
    my ($total_size, $ext_size) = @_;

    print BOLD GREEN sprintf("\nIn total %s of disk space was recovered:\n", format_size($total_size));
    print BOLD GREEN sprintf("- %s of disk space was recovered from %d %s sidecars (on average %s per file).\n",
        format_size($ext_size->{$_}),
        scalar @{ $files_to_delete->{$_} },
        $_,
        format_size($ext_size->{$_} / @{ $files_to_delete->{$_} }))
        for keys %$ext_size;
}

sub format_size {
    my $size = shift;
    my $exp = 0;

    for (@units) {
        last if $size < 1024;
        $size /= 1024;
        $exp++;
    }

    return sprintf("%.2f %s", $size, $units[$exp]);
}

define_extensions;
traverse_tree($ARGV[0] // '.');
delete_files if prompt;

