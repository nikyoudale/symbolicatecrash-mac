#!/usr/bin/perl -w
#
# This script parses a crashdump file and attempts to resolve addresses into function names.
#
# It finds symbol-rich binaries by:
#   a) searching in Spotlight to find .dSYM files by UUID, then finding the executable from there.
#       That finds the symbols for binaries that a developer has built with "DWARF with dSYM File".
#   b) searching in various SDK directories.
#
#
# Nik Youdale:
# Heavily modified version of the 'symbolicatecrash' script distributed with the iOS SDK
# The modifications simplify the script, and allow it to work for Mac app crash logs
#
# 
# Original copyright message:
# Copyright (c) 2008-2011 Apple Inc. All Rights Reserved.
#
#

use strict;
use warnings;
use Getopt::Std;
use Cwd qw(realpath);
use List::MoreUtils qw(uniq);
use File::Basename qw(basename);

#############################

# Forward definitons
sub usage();

#############################

# read and parse command line
my %opt;
$Getopt::Std::STANDARD_HELP_VERSION = 1;

getopts('Ahvo:',\%opt);

usage() if $opt{'h'};

#############################

# have this thing to de-HTMLize Leopard-era plists
my %entity2char = (
    # Some normal chars that have special meaning in SGML context
    amp    => '&',  # ampersand 
    'gt'    => '>',  # greater than
    'lt'    => '<',  # less than
    quot   => '"',  # double quote;  this " character in the comment keeps Xcode syntax coloring happy 
    apos   => "'",  # single quote '
    );

# Array of all the supported architectures.
my %architectures = (
    ARM      =>  "armv6",
    X86      =>  "i386",
    "X86-64" =>  "x86_64",
    PPC      =>  "ppc",
    "PPC-64" =>  "ppc64",
    "ARMV4T" =>  "armv4t",
    "ARMV5"  =>  "armv5",
    "ARMV6"  =>  "armv6",
    "ARMV7"  =>  "armv7",
);

#############################
# run the script

symbolicate_log(@ARGV);


#############################

# begin subroutines

sub HELP_MESSAGE() {
    usage();
}

sub usage() {
print STDERR <<EOF;
usage: 
    $0 [-h] [-o <OUTPUT_FILE>] LOGFILE [SYMBOL_PATH ...]
    
    Symbolicates a crashdump LOGFILE which may be "-" to refer to stdin. By default,
    all heuristics will be employed in an attempt to symbolicate all addresses. 
    Additional symbol files can be found under specified directories.
    
Options:
    
    -o  If specified, the symbolicated log will be written to OUTPUT_FILE (defaults to stdout)
    -h  Display this message
    -v  Verbose
EOF
exit 1;
}


#########

sub UUIDFromImage {
    my ($path, $arch) = @_;
    
    if ( ! -f $path ) {
        print STDERR "## $path doesn't exist " if $opt{v};
        return undef;
    }
    
    my $cmd = "lipo -info '$path'";
    print STDERR "Running $cmd\n" if $opt{v};
    
    my $lipo_result = `$cmd`;
    if( index($lipo_result, $arch) < 0) {
        print STDERR "## $path doesn't contain $arch slice\n" if $opt{v};
        return undef;
    }
    
    $cmd = "dwarfdump --uuid --arch $arch '$path'";
    
    print STDERR "Running $cmd\n" if $opt{v};
    
    my $TEST_uuid = `$cmd`;
    
    if ( $TEST_uuid =~ /UUID:\s*([0-9A-Fa-f-]+)/) {
        return $1
    } else {
        print STDERR "Can't understand the output from dwarfdump ($TEST_uuid -> $cmd)\n";
    }

    return undef;
}

sub matchesUUID {  
    my ($path, $uuid, $arch) = @_;
    
    my $imageUUID = UUIDFromImage($path, $arch);
    
    if ( $imageUUID eq $uuid ) {
        return 1;
    }
    
    return 0;
}


###########################
# crashlog parsing
###########################

# options:
#  - regex: don't escape regex metas in name
#  - continuous: don't reset pos when done.
#  - multiline: expect content to be on many lines following name
sub parse_section {
    my ($log_ref, $name, %arg ) = @_;
    my $content;
    
    $name = quotemeta($name) 
    unless $arg{regex};
    
    # content is thing from name to end of line...
    if( $$log_ref =~ m{ ^($name)\: [[:blank:]]* (.*?) $ }mgx ) {
        $content = $2;
        $name = $1;
        
        # or thing after that line.
        if($arg{multiline}) {
            $content = $1 if( $$log_ref =~ m{ 
                \G\n    # from end of last thing...
                (.*?) 
                (?:\n\s*\n|$) # until next blank line or the end
            }sgx ); 
        }
    } 
    
    pos($$log_ref) = 0 
    unless $arg{continuous}; 
    
    return ($name,$content) if wantarray;
    return $content;
}

# convenience method over above
sub parse_sections {
    my ($log_ref,$re,%arg) = @_;
    
    my ($name,$content);
    my %sections = ();
    
    while(1) {
        ($name,$content) = parse_section($log_ref,$re, regex=>1,continuous=>1,%arg);
        last unless defined $content;
        $sections{$name} = $content;
    } 
    
    pos($$log_ref) = 0;
    return \%sections;
}

sub parse_image {
    my ($log_ref,$bundle_id) = @_;
    my $section = parse_section($log_ref,'Binary Images',multiline=>1);
    if (!defined($section)) {
        die "Error: Can't find \"Binary Images\" section in log file";
    }
    
    my @lines = split /\n/, $section;
    for my $line (@lines) {
        if ($line =~ /$bundle_id/) {
            return $line;
        }
    }
    
    return undef;
}

sub parse_image_uuid {
    my ($log_ref,$bundle_id) = @_;
    
    my $imageInfo = parse_image($log_ref,$bundle_id);
    
    if ($imageInfo =~ /$bundle_id\s*\(.*\)\s*\<([[:xdigit:]-]+)\>/) {
        return $1;
    }
    
    die "Error: Couldn't find UUID for binary image for '$bundle_id'";
    return undef;
}

sub parse_load_address {
    my ($log_ref,$bundle_id) = @_;
    
    my $imageInfo = parse_image($log_ref,$bundle_id);

    if ($imageInfo =~ /\s*([x[:xdigit:]]+)/) {
        return $1;
    }

    die "Error: Couldn't find UUID for binary image for '$bundle_id'";
    return undef;
}

# returns an oddly-constructed hash:
#  'string-to-replace' => { bundle=>..., address=>... }
sub parse_backtrace {
    my ($backtrace,$images) = @_;
    my @lines = split /\n/,$backtrace;
    
    my %frames = ();
    for my $line (@lines) {
        if( $line =~ m{
            ^\d+ \s+     # stack frame number
            (\S.*?) \s+    # bundle id (1)
            ((0x\w+) \s+   # address (3)
            .*) \s* $    # current description, to be replaced (2)
        }x ) {
            my($bundle,$replace,$address) = ($1,$2,$3);
            # print STDERR "Parse_bt: $bundle,$replace,$address\n" if ($opt{v});
            
            # disambiguate within our hash of binaries
            # $bundle = findImageByNameAndAddress($images, $bundle, $address);
            
            # skip unless we know about the image of this frame
            next unless 
            $$images{$bundle};
            
            $frames{$replace} = {
                'address' => $address,
                'bundle'  => $bundle,
            };
            
        }
        #        else { print "unable to parse backtrace line $line\n" }
    }
    
    return \%frames;
}

sub slurp_file {
    my ($file) = @_;
    my $data;
    my $fh;
    my $readingFromStdin = 0;
    
    local $/ = undef;
    
    # - or "" mean read from stdin, otherwise use the given filename
    if($file && $file ne '-') {
        open $fh,"<",$file or die "while reading $file, $! : ";
    } else {
        open $fh,"<&STDIN" or die "while readin STDIN, $! : ";
        $readingFromStdin = 1;
    }
    
    $data = <$fh>;
    
    
    # Replace DOS-style line endings
    $data =~ s/\r\n/\n/g;
    
    # Replace Mac-style line endings
    $data =~ s/\r/\n/g;
    
    # Replace "NO-BREAK SPACE" (these often get inserted when copying from Safari)
    # \xC2\xA0 == U+00A0
    $data =~ s/\xc2\xa0/ /g;
    
    close $fh or die $!;
    return \$data;
}

sub parse_OSVersion {
    my ($log_ref) = @_;
    my $section = parse_section($log_ref,'OS Version');
    if ( $section =~ /\s([0-9\.]+)\s+\(Build (\w+)/ ) {
        return ($1, $2)
    }
    if ( $section =~ /\s([0-9\.]+)\s+\((\w+)/ ) {
        return ($1, $2)
    }
    if ( $section =~ /\s([0-9\.]+)/ ) {
        return ($1, "")
    }
    die "Error: can't parse OS Version string $section";
}

sub parse_bundle_identifier {
    my ($log_ref) = @_;
    my $pluginIdentifier = parse_section($log_ref,'PlugIn Identifier');
    $pluginIdentifier =~ /([\w\.]+)/;
    my $identifier = parse_section($log_ref,'Identifier');
    $identifier =~ /([\w\.]+)/;
    return length($pluginIdentifier) > 0 ? basename($pluginIdentifier) : basename($identifier);
}

sub parse_executable_name {
    my ($log_ref) = @_;
    my $pluginPath = parse_section($log_ref,'PlugIn Path');
    my $path = parse_section($log_ref,'Path');
    return length($pluginPath) > 0 ? basename($pluginPath) : basename($path);
}

# Map from the "Code Type" field of the crash log, to a Mac OS X
# architecture name that can be understood by otool.
sub parse_arch {
    my ($log_ref) = @_;
    my $codeType = parse_section($log_ref,'Code Type');
    $codeType =~ /([\w-]+)/;
    my $arch = $architectures{$1};
    die "Error: Unknown architecture $1" unless defined $arch;
    return $arch;
}

sub parse_report_version {
    my ($log_ref) = @_;
    my $version = parse_section($log_ref,'Report Version');
    $version or return undef;
    $version =~ /(\d+)/;
    return $1;
}

# run atos
sub symbolize_frames {
    my ($images,$bt) = @_;
    
    # create mapping of framework => address => bt frame (adjust for slid)
    # and for framework => arch
    my %frames_to_lookup = ();
    my %arch_map = ();
    my $load_address = undef;
    
    for my $k (keys %$bt) {
        # print STDERR "key: '$k'\n" if ($opt{v});
        my $frame = $$bt{$k};
        # print STDERR "frame: '$$frame{bundle}'\n" if ($opt{v});
        
        my $lib = $$images{$$frame{bundle}};
        unless($lib) {
            # don't know about it, can't symbol
            # should have already been warned about this!
            # print "Skipping unknown $$frame{bundle}\n";
            delete $$bt{$k};
            next;
        }
        
        $load_address = $$lib{load_address};
        
        my $address = $$frame{address};
        
        # list of address to lookup, mapped to the frame object, for
        # each library
        $frames_to_lookup{$$lib{symbol}}{$address} = $frame;
        $arch_map{$$lib{symbol}} = $$lib{arch};
    }
    
    # run atos for each library
    while(my($symbol,$frames) = each(%frames_to_lookup)) {
        # escape the symbol path if it contains single quotes
        my $escapedSymbol = $symbol;
        $escapedSymbol =~ s/\'/\'\\'\'/g;
        
        # run atos with the addresses and binary files we just gathered
        my $arch = $arch_map{$symbol};
        # my $cmd = "$atos -arch $arch -o '$escapedSymbol' @{[ keys %$frames ]} | ";
        my $cmd = "atos -arch $arch -l $load_address -o '$escapedSymbol' @{[ keys %$frames ]} | ";
        
        print STDERR "Running $cmd\n" if $opt{v};
        
        open my($ph),$cmd or die $!;
        my @symbolled_frames = map { chomp; $_ } <$ph>;
        close $ph or die $!;
        
        my $references = 0;
        
        foreach my $symbolled_frame (@symbolled_frames) {
            
            $symbolled_frame =~ s/\s*\(in .*?\)//; # clean up -- don't need to repeat the lib here
            
            # find the correct frame -- the order should match since we got the address list with keys
            my ($k,$frame) = each(%$frames);
            
            if ( $symbolled_frame !~ /^\d/ ) {
                # only symbolicate if we fetched something other than an address
                $$frame{symbolled} = $symbolled_frame;
                $references++;
            }
            
        }
        
        if ( $references == 0 ) {
            print STDERR "## Warning: Unable to symbolicate from required binary: $symbol\n";
        }
    }
    
    # just run through and remove elements for which we didn't find a
    # new mapping:
    while(my($k,$v) = each(%$bt)) {
        delete $$bt{$k} unless defined $$v{symbolled};
    }
}

# run the final regex to symbolize the log
sub replace_symbolized_frames {
    my ($log_ref,$bt)  = @_; 
    my $re = join "|" , map { quotemeta } keys %$bt;
    
    my $log = $$log_ref;
    $log =~ s#$re#
    my $frame = $$bt{$&};
    $$frame{address} ." ". $$frame{symbolled};
    #esg;
    
    $log =~ s/(&(\w+);?)/$entity2char{$2} || $1/eg;
    
    return \$log;
}

#############

sub output_log($) {
  my ($log_ref)  = @_;
  
  if($opt{'o'}) {
    close STDOUT;
    open STDOUT, '>', $opt{'o'};
  }
  
  print $$log_ref;
}

#############

sub symbolicate_log {
    my ($crash_log_file,@extra_search_paths) = @_;
    
    print STDERR "Symbolicating...\n" if ( $opt{v} );
    
    my $log_ref = slurp_file($crash_log_file);
    
    print STDERR length($$log_ref)." characters read.\n" if ( $opt{v} );
    
    # get the version number
    my $report_version = parse_report_version($log_ref);
    $report_version or die "No crash report version in $crash_log_file";
    
    my $dSYM_path = shift(@extra_search_paths);
    if (!defined($dSYM_path)) {
        die "Error: No dSYM file specified\n";
    }
    
    my $bundle_id = parse_bundle_identifier($log_ref);
    my $executable_name = parse_executable_name($log_ref);
    my $uuid = parse_image_uuid ($log_ref, $bundle_id);
    my $load_address = parse_load_address ($log_ref, $bundle_id);
    my $symbol = "$dSYM_path/Contents/Resources/DWARF/$executable_name";
    my $arch = parse_arch($log_ref);
    
    print STDERR "Bundle ID: $bundle_id\n" if $opt{v};
    print STDERR "Excutable name: $executable_name\n" if $opt{v};
    print STDERR "Load address: $load_address\n" if $opt{v};
    print STDERR "Image UUID: $uuid\n" if $opt{v};
    print STDERR "Symbol path: $symbol\n" if $opt{v};
    print STDERR "Architecture: $arch\n" if $opt{v};
    
    if (!matchesUUID($symbol, $uuid, $arch)) {
        my $symbolUUID = UUIDFromImage($symbol, $arch);
        die "Error: Symbol UUID <$symbolUUID> does not match crash log image UUID <$uuid>";
    }
    
    my $images = {
        "$bundle_id" => {
            uuid => $uuid,
            arch => $arch,
            symbol => $symbol,
            load_address => $load_address,
        }
    };
    
    my $bt = {};
    my $threads = parse_sections($log_ref,'Thread\s+\d+\s?(Highlighted|Crashed)?',multiline=>1);
    for my $thread (values %$threads) {
        # merge all of the frames from all backtraces into one
        # collection
        my $b = parse_backtrace($thread,$images);
        @$bt{keys %$b} = values %$b;
    }
    
    # extract build
    my ($version, $build) = parse_OSVersion($log_ref);
    print STDERR "OS Version $version Build $build\n" if $opt{v};
        
        
    # run atos
    symbolize_frames($images,$bt);
    
    if(keys %$bt) {
        # run our fancy regex
        my $new_log = replace_symbolized_frames($log_ref,$bt);
        output_log($new_log);
    } else {
        #There were no symbols found
        print STDERR "No symbolic information found\n";
        output_log($log_ref);
    }
}
