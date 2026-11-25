#!/usr/bin/perl
# tests/fixtures/doc_forms.pl: turns the command synopses the docs show into
# concrete argument lists for tests/docs.sh, which runs each one through pbo's
# parser (with --dry-run) and fails on a usage error (64): a documented form
# the parser rejects is a doc bug, or a parser bug.
#
# Input on stdin, one per line: MODE <tab> ID <tab> TEXT
#   MODE H  a synopsis from `pbo help` or the README command list, without
#           its description: `doctor [--fix [--fix-parents]] [--perms-only]`
#   MODE C  a command line from a code block, without the leading `pbo`:
#           shell quotes are honoured, a `#` comment and a `| program` pipe
#           end it; [ ] mark an optional part as in a synopsis (the runbook
#           writes `pbo list [vmid]`)
# Output, one form per line: ID <tab> WORDS joined by \x1f. A synopsis gives
# several forms: the minimal one (no optional part, the first of each set of
# alternatives), each optional part and each alternative alone, and all
# optional parts at once. Not every combination: the forms are linear in the
# number of options, and a flag the parser rejects shows up in the one that
# adds it. An error (an unknown placeholder, an unbalanced bracket) prints
#   ID <tab> ERROR: <message>
#
# Synopsis grammar: words; [ ... ] optional; ` | ` (blanks around it) between
# alternatives of the whole line or of a group (a later alternative at the
# top level that does not start with the command word gets it: `job list |
# show <id>`); a|b inside a word, or <a|b>, are alternatives of that word;
# a trailing `...` (repetition) is dropped.
#
# Arguments: the placeholders, as `<name>=value` (inside angle brackets) or
# `NAME=value` (a bare word such as N or F). A name given twice gives its
# values in turn, by position in the line: `<KEY>=A <KEY>=B` maps the first
# <KEY> of a line to A, the second to B. An empty value drops the word.
# `--abs=DIR`: an absolute path in a code block (/srv/pbo-cache) becomes a
# path below DIR, so no documented command makes pbo resolve a host path.
use strict;
use warnings;

my (%ph, $abs);
for my $a (@ARGV) {
    if ($a =~ /^--abs=(.+)$/) { $abs = $1; next }
    $a =~ /^([^=]+)=(.*)$/s or die "doc_forms: bad argument '$a'\n";
    push @{ $ph{$1} }, $2;
}
die "doc_forms: --abs=DIR is required\n" unless defined $abs;

my %seen;    # per line: how often a placeholder was used

# tokens TEXT MODE: [kind, word, literal] with kind w (word), [, ], |
sub tokens {
    my ($s, $mode) = @_;
    my @t;
    my ($i, $n) = (0, length $s);
    while ($i < $n) {
        my $c = substr($s, $i, 1);
        if ($c =~ /\s/) { $i++; next }
        last if $mode eq 'C' && ($c eq '#' || $c eq '|');    # a comment, a pipe
        if ($c eq '[' || $c eq ']' || ($mode eq 'H' && $c eq '|')) { push @t, [$c]; $i++; next }
        my ($w, $lit) = ('', 0);
        while ($i < $n) {
            $c = substr($s, $i, 1);
            last if $c =~ /\s/;
            last if $c eq ']';
            if ($c eq "'" || $c eq '"') {
                my $j = index($s, $c, $i + 1);
                die "unclosed quote\n" if $j < 0;
                $w .= substr($s, $i + 1, $j - $i - 1);
                $lit = 1; $i = $j + 1; next;
            }
            if ($mode eq 'C' && $c eq '\\') { $w .= substr($s, $i + 1, 1); $i += 2; next }
            $w .= $c; $i++;
        }
        push @t, ['w', $w, $lit];
    }
    return @t;
}

# subst WORD: the placeholders replaced; undef drops the word
sub subst {
    my ($w) = @_;
    $w =~ s/\.\.\.$//;
    if (exists $ph{$w}) { return take($w) }                       # N, F, vmid, args
    $w =~ s/<([^<>]+)>/my $v = take("<$1>"); defined $v ? $v : ''/ge;
    die "a placeholder is left in '$w'\n" if $w =~ /[<>]/;
    $w = $abs . '/' . ($w =~ s{^/}{}r =~ s{/}{_}gr) if $w =~ m{^/} && index($w, $abs) != 0;
    return $w;
}
sub take {
    my ($name) = @_;
    my $l = $ph{$name} or die "no value for the placeholder $name\n";
    my $k = $seen{$name}++;
    my $v = $l->[$k < @$l ? $k : $#$l];
    return $v eq '' ? undef : $v;
}

# word_variants TOKEN: the forms one word gives (a|b, <a|b>: one each)
sub word_variants {
    my ($t) = @_;
    my ($w, $lit) = ($t->[1], $t->[2]);
    return [[$w]] if $lit;
    my @alts = $w =~ /^<([^<>]*\|[^<>]*)>$/ ? split(/\|/, $1) : ($w =~ /\|/ ? split(/\|/, $w) : ($w));
    my @v;
    for my $a (@alts) { my $s = subst($a); push @v, defined $s ? [$s] : [] }
    return \@v;
}

# combine VARIANTS...: the minimal form, each variant of each item alone, all at their last
sub combine {
    my @V = @_;
    my @min = map { $_->[0] } @V;
    my @out = ([map { @$_ } @min]);
    for my $i (0 .. $#V) {
        for my $j (1 .. $#{ $V[$i] }) { my @f = @min; $f[$i] = $V[$i][$j]; push @out, [map { @$_ } @f] }
    }
    push @out, [map { @$_ } map { $_->[-1] } @V];
    my (%u, @r);
    for my $f (@out) { my $k = join("\x1f", @$f); push @r, $f unless $u{$k}++ }
    return \@r;
}

# parse_seq TOKENS POS: the forms of a sequence up to ] or | (POS advanced)
sub parse_seq {
    my ($T, $p) = @_;
    my @V;
    while ($$p < @$T) {
        my $t = $T->[$$p];
        last if $t->[0] eq ']' || $t->[0] eq '|';
        if ($t->[0] eq '[') {
            $$p++;
            my @forms = @{ parse_seq($T, $p) };
            while ($$p < @$T && $T->[$$p][0] eq '|') { $$p++; push @forms, @{ parse_seq($T, $p) } }
            die "unbalanced [\n" unless $$p < @$T && $T->[$$p][0] eq ']';
            $$p++;
            push @V, [[], @forms];
        } else {
            push @V, word_variants($t);
            $$p++;
        }
    }
    return @V ? combine(@V) : [[]];
}

while (my $line = <STDIN>) {
    chomp $line;
    my ($mode, $id, $text) = split /\t/, $line, 3;
    next unless defined $text;
    %seen = ();
    my @out = eval {
        my @T = tokens($text, $mode);
        # the alternatives of the whole line (help: `job list | show <id>`)
        my (@chunks, @cur);
        my $depth = 0;
        for my $t (@T) {
            $depth++ if $t->[0] eq '[';
            $depth-- if $t->[0] eq ']';
            die "unbalanced ]\n" if $depth < 0;
            if ($t->[0] eq '|' && $depth == 0) { push @chunks, [@cur]; @cur = (); next }
            push @cur, $t;
        }
        die "unbalanced [\n" if $depth;
        push @chunks, [@cur];
        my $cmd = $chunks[0][0];
        die "no command word\n" unless $cmd && $cmd->[0] eq 'w';
        my @forms;
        for my $c (@chunks) {
            my @ct = @$c;
            unshift @ct, $cmd unless @ct && $ct[0][0] eq 'w' && $ct[0][1] eq $cmd->[1];
            my $p = 0;
            my $f = parse_seq(\@ct, \$p);
            die "unbalanced ]\n" if $p < @ct;
            push @forms, @$f;
        }
        @forms;
    };
    if ($@) { chomp(my $e = $@); print "$id\tERROR: $e\n"; next }
    print "$id\t", join("\x1f", @$_), "\n" for @out;
}
