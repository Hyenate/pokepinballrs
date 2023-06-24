#!/usr/bin/perl

# Usage:
#   calcrom.pl <mapfile> [--verbose]
#
#   mapfile: path to .map file output by LD
#   verbose: set to get more detailed output

use IPC::Cmd qw[ run ];
use Getopt::Long;

my $usage = "Usage: calcrom.pl file.map [--verbose]\n";
my $verbose = "";

GetOptions("verbose" => \$verbose) or die $usage;
(@ARGV == 1)
    or die $usage;
open(my $file, $ARGV[0])
    or die "ERROR: could not open file '$ARGV[0]'.\n";

my $src = 0;
my $asm = 0;
my $srcdata = 0;
my $data = 0;
my @pairs = ();

my $processlines = 0;

while (my $line = <$file>)
{
    # Prevent everything before Memory Configuration from being considered, most notably discarded sections
    if (rindex($line, 'Memory Configuration', 0) == 0)
    {
        $processlines = 1;
    }
    
    if (!$processlines)
    {
        next;
    }
    
    if ($line =~ /^ \.(\w+)\s+0x[0-9a-f]+\s+(0x[0-9a-f]+) (\w+)\/(.+)\.o/)
    {
        my $section = $1;
        my $size = hex($2);
        my $dir = $3;
        my $basename = $4;
        if ($size & 3)
        {
            $size += 4 - ($size & 3);
        }

        if ($section =~ /text/)
        {
            if ($dir eq 'src')
            {
                $src += $size;
            }
            elsif ($dir eq 'asm')
            {
                if (!($basename =~ /(crt0|libagbsyscall|libgcnmultiboot|m4a_1)/))
                {
                    push @pairs, [$basename, $size];
                }
                $asm += $size;
            }
        }
        elsif ($section =~ /rodata/)
        {
            if ($dir eq 'src')
            {
                print "$line";
                $srcdata += $size;
            }
            elsif ($dir eq 'data')
            {
                $data += $size;
            }
        }
    }
}

my @sorted = sort { $a->[1] <=> $b->[1] } @pairs;
(my $elffname = $ARGV[0]) =~ s/\.map/.elf/;



# Note that the grep filters out all branch labels. It also requires a minimum
# line length of 5, to filter out a ton of generated symbols (like AcCn). No
# settings to nm seem to remove these symbols. Finally, nm prints out a separate
# entry for whenever a name appears in a file, not just where it's defined. uniq
# removes all the duplicate entries.
#
#
# You'd expect this to take a while, because of uniq. It runs in under a second,
# though. Uniq is pretty fast!
my $base_cmd = "nm $elffname | awk '{print \$3}' | grep '^[^_].\\{4\\}' | uniq";

# This looks for Unknown_, Unknown_, or sub_, followed by just numbers. Note that
# it matches even if stuff precedes the unknown, like sUnknown/gUnknown.
# 'sub_' anchors to the start so it does not consider symbols like 'nullsub_12' undocumented.
my $undoc_cmd = "grep -E '[Uu]nknown_[0-9a-fA-F]{4,}\$|^sub_[0-9a-fA-F]{4,}\$'";

# This looks for every symbol with an address at the end of it. Some things are
# given a name based on their type / location, but still have an unknown purpose.
# For example, FooMap_EventScript_FFFFFFF.
my $partial_doc_cmd = "grep -E '_[0-9a-fA-F]{4,}\$'";

my $count_cmd = "wc -l";

my $incbin_cmd = "find \"\$(dirname $elffname)\" \\( -name '*.s' -o -name '*.inc' \\) -exec cat {} ';' | grep -oE '^\\s*\\.incbin\\s*\"[^\"]+\"\s*,\\s*(0x)?[0-9a-fA-F]+\\s*,\\s*(0x)?[0-9a-fA-F]+' -";

# It sucks that we have to run this three times, but I can't figure out how to get
# stdin working for subcommands in perl while still having a timeout. It's decently
# fast anyway.
my $total_syms_as_string;
(run (
    command => "$base_cmd | $count_cmd",
    buffer => \$total_syms_as_string,
    timeout => 60
))
    or die "ERROR: Error while getting all symbols: $?";

my $undocumented_as_string;
(run (
    command => "$base_cmd | $undoc_cmd | $count_cmd",
    buffer => \$undocumented_as_string,
    timeout => 60
))
    or die "ERROR: Error while filtering for undocumented symbols: $?";

my $partial_documented_as_string;
(run (
    command => "$base_cmd | $partial_doc_cmd | $count_cmd",
    buffer => \$partial_documented_as_string,
    timeout => 60
))
    or die "ERROR: Error while filtering for partial symbols: $?";

my $incbin_count_as_string;
(run (
    command => "$incbin_cmd | $count_cmd",
    buffer => \$incbin_count_as_string,
    timeout => 60
))
    or die "ERROR: Error while counting incbins: $?";

my $incbin_bytes_as_string;
(run (
    command => "(echo -n 'ibase=16;' ; $incbin_cmd | sed -E 's/.*,\\s*0x([0-9a-fA-F]+)/\\1/' | tr '\\n' '+'; echo '0' ) | bc",
    buffer => \$incbin_bytes_as_string,
    timeout => 60
))
    or die "ERROR: Error while calculating incbin totals: $?";

# Performing addition on a string converts it to a number. Any string that fails
# to convert to a number becomes 0. So if our converted number is 0, but our string
# is nonzero, then the conversion was an error.
my $undocumented = $undocumented_as_string + 0;
(($undocumented != 0) and ($undocumented_as_string ne "0"))
    or die "ERROR: Cannot convert string to num: '$undocumented_as_string'";

my $partial_documented = $partial_documented_as_string + 0;
(($partial_documented != 0) and ($partial_documented_as_string ne "0"))
	or die "ERROR: Cannot convert string to num: '$partial_documented_as_string'";

my $total_syms = $total_syms_as_string + 0;
(($total_syms != 0) and ($total_syms_as_string ne "0"))
    or die "ERROR: Cannot convert string to num: '$total_syms_as_string'";

($total_syms != 0)
    or die "ERROR: No symbols found.";

my $incbin_count = $incbin_count_as_string + 0;
(($incbin_count != 0) and ($incbin_count_as_string ne "0"))
    or die "ERROR: Cannot convert string to num: '$incbin_count_as_string'";

my $incbin_bytes = $incbin_bytes_as_string + 0;
(($incbin_bytes != 0) and ($incbin_bytes_as_string ne "0"))
    or die "ERROR: Cannot convert string to num: '$incbin_bytes_as_string'";


my $total = $src + $asm;
my $srcPct = sprintf("%.4f", 100 * $src / $total);
my $asmPct = sprintf("%.4f", 100 * $asm / $total);

# partial_documented is double-counting the unknown_* and sub_* symbols.
$partial_documented = $partial_documented - $undocumented;

my $documented = $total_syms - ($undocumented + $partial_documented);
my $docPct = sprintf("%.4f", 100 * $documented / $total_syms);
my $partialPct = sprintf("%.4f", 100 * $partial_documented / $total_syms);
my $undocPct = sprintf("%.4f", 100 * $undocumented / $total_syms);

if ($asm == 0)
{
    print "Code decompilation is 100% complete\n"
}
else
{
    print "$total total bytes of code\n";
    print "$src bytes of code in src ($srcPct%)\n";
    print "$asm bytes of code in asm ($asmPct%)\n";
}
print "\n";



if ($verbose != 0)
{
    print "BREAKDOWN\n";
    foreach my $item (@sorted)
    {
        print "    $item->[1] bytes in asm/$item->[0].s\n"
    }
    print "\n";
}



if ($partial_documented == 0 && $undocumented == 0)
{
    print "Documentation is 100% complete\n"
}
else
{
    print "$total_syms total symbols\n";
    print "$documented symbols documented ($docPct%)\n";
    print "$partial_documented symbols partially documented ($partialPct%)\n";
    print "$undocumented symbols undocumented ($undocPct%)\n";
}

print "\n";
my $dataTotal = $srcdata + $data;
my $srcDataPct = sprintf("%.4f", 100 * $srcdata / $dataTotal);
my $dataPct = sprintf("%.4f", 100 * $data / $dataTotal);

my $incPct = sprintf("%.4f", 100 * $incbin_bytes / $dataTotal);

if ($data == 0)
{
    print "Data porting to C is 100% complete\n"
}
else
{
    print "$dataTotal total bytes of data\n";
    print "$srcdata bytes of data in src ($srcDataPct%)\n";
    print "$data bytes of data in data ($dataPct%)\n";
}

print "\n";

if ($incbin_count == 0) {
    print "All incbins have been eliminated\n"
} else {
    print "$incbin_bytes bytes of data in $incbin_count incbins ($incPct%)\n"
}
