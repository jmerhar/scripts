#!/usr/bin/env perl
#
# A script to find and delete "sidecar" files (e.g., JPEGs) when a
# corresponding RAW photo file with the same base name exists in the same directory.
#
# This is useful for cleaning up photo collections where you only want to keep
# the RAW file for archival purposes once you have finished editing.
#
# The script traverses a directory tree, prompts the user with what it finds,
# and then deletes the files upon confirmation.

use strict;
use warnings;
# Term::ANSIColor is used for colored terminal output.
use Term::ANSIColor qw( :constants );
use File::Spec;
use File::Basename;

# --- Global Variables ---
# A hash to store a list of sidecar files to be deleted, now grouped by the RAW extension.
my $files_to_delete = {};
# Standard units for formatting file sizes.
my @units = qw( B KB MB GB TB PB );
# Arrays to hold user-defined file extensions.
my @sidecar_extensions;
my @raw_extensions;

# Automatically reset terminal colors after each colored print.
$Term::ANSIColor::AUTORESET = 1;

#######################################
# Returns a list of unique elements from an array.
# Globals:
#   None
# Arguments:
#   An array of strings.
# Outputs:
#   An array with duplicate elements removed.
#######################################
sub uniq {
    my %seen;
    grep !$seen{$_}++, @_;
}

#######################################
# Reads a single line of input from the user.
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   The user's input as a string.
#######################################
sub read_answer {
    # Temporarily disable autoreset to keep the input text white.
    local $Term::ANSIColor::AUTORESET = 0;
    print BRIGHT_WHITE;
    my $answer = <STDIN>;
    chomp $answer;
    print RESET;
    return $answer;
}

#######################################
# Prompts the user to define which file extensions to treat as sidecars
# and which to treat as RAW photos.
# Globals:
#   @sidecar_extensions, @raw_extensions
# Arguments:
#   None
# Outputs:
#   Populates the global @sidecar_extensions and @raw_extensions arrays.
#######################################
sub define_extensions {
    my $sidecars = 'JPG jpg JPEG jpeg';
    my $raws     = 'RW2 CR2 DNG dng';

    print BOLD CYAN "What extensions do your sidecars have? ";
    print FAINT WHITE "[$sidecars] ";
    @sidecar_extensions = split(' ', read_answer || $sidecars);

    print BOLD CYAN "What extensions do your raw photos have? ";
    print FAINT WHITE "[$raws] ";
    @raw_extensions = split(' ', read_answer || $raws);

    print "\n";
}

#######################################
# Recursively traverses a directory tree and processes each directory.
# Globals:
#   None
# Arguments:
#   The path to the directory to start traversing from.
#######################################
sub traverse_tree {
    my ($dir) = @_;
    opendir(my $dh, $dir) || die "Can't open $dir: $!";
    print FAINT YELLOW "Scanning directory $dir\n";

    # Collect all files in the current directory, grouped by base name.
    my $files = {};
    while (readdir $dh) {
        next if m/^\.+$/; # skip . and ..

        my $filename = $_;
        my $path = File::Spec->catfile($dir, $filename);

        if (-d $path) {
            # If it's a directory, recurse into it.
            traverse_tree($path);
        } else {
            # If it's a file, parse its name and extension.
            next unless $filename =~ m/^(.*)\.([^.]+)$/;
            # Store the extension for the given base name.
            $files->{$1}{$2} = 1;
        }
    }

    closedir($dh);
    # Process the files found in this directory.
    process_dir($dir, $files);
}

#######################################
# Identifies sidecar files within a single directory's file list.
# This is the core logic of the script.
# Globals:
#   @raw_extensions, @sidecar_extensions, $files_to_delete
# Arguments:
#   dir: The directory being processed.
#   files: A hash of files from that directory, grouped by base name.
#######################################
sub process_dir {
    my ($dir, $files) = @_;

    # Iterate over each unique file base name (e.g., "IMG_1234").
    for my $name (keys %$files) {
        my $extensions_present = $files->{$name};
        my $found_raw_ext = undef;

        # First, check if a RAW file exists for this base name.
        for my $raw_ext (@raw_extensions) {
            if ($extensions_present->{$raw_ext}) {
                $found_raw_ext = $raw_ext;
                last;
            }
        }

        # If no RAW file was found for this name, we don't touch anything.
        next unless $found_raw_ext;

        # If a RAW file WAS found, now we check for sidecar files to delete.
        for my $sidecar_ext (@sidecar_extensions) {
            if ($extensions_present->{$sidecar_ext}) {
                my $sidecar_file_path = File::Spec->catfile($dir, "$name.$sidecar_ext");
                # **THE FIX**: Use the RAW extension as the key, so the report is grouped correctly.
                push @{ $files_to_delete->{$found_raw_ext} }, $sidecar_file_path;
            }
        }
    }
}

#######################################
# Prompts the user with a summary of found sidecars and asks for action.
# Globals:
#   $files_to_delete, @sidecar_extensions
# Arguments:
#   None
# Returns:
#   True if the user chooses to delete, false otherwise.
#######################################
sub prompt {
    if (! keys %$files_to_delete) {
        print BRIGHT_GREEN "\nNo sidecar files found to delete.\n";
        exit;
    }

    print BOLD GREEN "\nFound sidecars for the following RAW types:\n";
    for my $raw_ext (sort keys %$files_to_delete) {
        print BOLD GREEN sprintf("- %d sidecars for %s files\n", scalar @{ $files_to_delete->{$raw_ext} }, $raw_ext);
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

#######################################
# Prints a summary of directories where sidecar files were found.
# Globals:
#   $files_to_delete
# Arguments:
#   None
#######################################
sub print_directories {
    for my $raw_ext (sort keys %$files_to_delete) {
        print BOLD GREEN sprintf("\nFound sidecars for %s files in the following directories:\n", $raw_ext);
        my $count = {};
        # A bit of map/grep magic to get a unique, sorted list of directories and their counts.
        for my $dir (sort(uniq(map { $count->{dirname($_)}++; dirname($_) } @{ $files_to_delete->{$raw_ext} }))) {
            print BOLD YELLOW sprintf("[%5d] %s\n", $count->{$dir}, $dir);
        }
    }
}

#######################################
# Deletes the identified sidecar files from the disk.
# Globals:
#   $files_to_delete
# Arguments:
#   None
#######################################
sub delete_files {
    my $total_size = 0;
    my $ext_size;
    for my $raw_ext (keys %$files_to_delete) {
        # The value is the list of sidecar files to delete for that RAW type.
        for my $file (@{ $files_to_delete->{$raw_ext} }) {
            my $size = -s $file // 0;
            print MAGENTA sprintf("Deleting %s (%s), a sidecar for a %s file\n", $file, format_size($size), $raw_ext);
            $total_size += $size;
            $ext_size->{$raw_ext} += $size;
            # The actual file deletion happens here.
            unlink $file;
        }
    }
    print_report($total_size, $ext_size);
}

#######################################
# Prints a final report summarizing the space recovered.
# Globals:
#   $files_to_delete
# Arguments:
#   total_size: The total bytes recovered.
#   ext_size: A hash mapping RAW extension to bytes recovered.
#######################################
sub print_report {
    my ($total_size, $ext_size) = @_;

    return unless $total_size > 0;

    print BOLD GREEN sprintf("\nIn total %s of disk space was recovered:\n", format_size($total_size));
    for my $raw_ext (sort keys %$ext_size) {
        my $count = scalar @{ $files_to_delete->{$raw_ext} };
        next unless $count > 0;
        print BOLD GREEN sprintf("- %s by deleting %d sidecars for %s files (average %s per file).\n",
            format_size($ext_size->{$raw_ext}),
            $count,
            $raw_ext,
            format_size($ext_size->{$raw_ext} / $count));
    }
}

#######################################
# Formats a size in bytes into a human-readable string (KB, MB, GB, etc.).
# Globals:
#   @units
# Arguments:
#   The size in bytes.
# Returns:
#   A formatted string (e.g., "1.23 MB").
#######################################
sub format_size {
    my $size = shift // 0;
    return "0 B" if $size == 0;
    my $exp = 0;

    for (@units) {
        last if $size < 1024;
        $size /= 1024;
        $exp++;
    }

    return sprintf("%.2f %s", $size, $units[$exp]);
}


# --- Main execution block ---
# 1. Ask the user to define file extensions.
define_extensions;
# 2. Traverse the directory tree starting from the path given on the command line, or the current directory.
traverse_tree($ARGV[0] // '.');
# 3. Prompt the user for action and delete files if they confirm.
delete_files if prompt;
