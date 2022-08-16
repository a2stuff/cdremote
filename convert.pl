#!/usr/bin/env perl

use warnings;
use strict;

sub rebytes($) {
    my ($s) = @_;
    $s =~ s/\b([0-9A-F]{2})\b/\$$1/ig;
    $s =~ s/ /, /g;
    return $s;
}

sub relabel($) {
    my ($s) = @_;
    $s =~ s/[^A-Za-z0-9_,]/_/g;
    return $s;
}

print <<'EOD';
.setcpu "65c02"
.org $4000
ZP1                 := $19
ZP2                 := $1B
ZP3                 := $1D
PlayedListPtr       := $1F


MLIEntry            := $BF00

Kbd                 := $C000
KbdStrobe           := $C010
SetGraphics         := $C050
SetFullScreen       := $C052
SetPage1            := $C054
SetHiRes            := $C057
OpenApple           := $C061

CardROMByte         := $C5FF

EOD



while (<STDIN>) {
    chomp;

    $_ =~ s/<-/LA/g;
    $_ =~ s/->/RA/g;
    $_ =~ s/BLiT /BLiT_/g;

    my $label = substr($_, 0, 20);
    my $rest  = length($_) >= 20 ? substr($_, 20) : '';

    next if $rest =~ /^\?\?/;


    if ($label =~ /^(\S+) (\s*)/ && $rest !~ /^:=/) {
        $label = relabel($1) . ':' . $2;
    }

    if ($rest =~ /^\s*(([0-9A-F]{2}( |$))+)/i) {
        $rest = '.byte   ' . rebytes($1);
    }

    if ($rest =~ /^([a-z]{3}) ([A-Z]\S+)(.*)/) {
        $rest = $1 . ' ' . relabel($2) . $3;
    }

    if ($rest =~ /^(\S+)$/ && $rest !~ /^[a-z]{3}$/) {
        $rest = '.addr   ' . relabel($rest);
    }

    $label =~ s/NotPaused/\@NotPaused/g;
    $rest =~ s/NotPaused/\@NotPaused/g;

    print $label . $rest . "\n";
}
