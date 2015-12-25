use strict;
use warnings;
use autodie;

use blib "ouroboros/blib";

use Config;
use Config::Perl::V;

use Ouroboros;
use File::Slurp qw/read_file write_file/;
use File::Spec::Functions qw/catfile/;

use constant {
    EMBED_FNC_PATH => "build/embed.fnc",
    OURO_TXT_PATH => "ouroboros/libouroboros.txt",
    OUT_DIR => $ENV{OUT_DIR} // ".",
    OUT_NAME => "perl_defs.rs",

    STUB_TYPES => [
        "PerlInterpreter",
        "PerlIO",
        "SV",
        "AV",
        "HV",
        "HE",
        "GV",
        "CV",
        "OP",
        "IO",
        "BHK",
        "PERL_CONTEXT",
        "MAGIC",
        "MGVTBL",
        "PADLIST",
        "PADNAME",
        "PADNAMELIST",
        "HEK",
        "UNOP_AUX_item",
        "LOOP",
    ],

    TYPEMAP => {
        "ouroboros_stack_t" => "*mut OuroborosStack",

        "void" => "::std::os::raw::c_void",
        "int" => "::std::os::raw::c_int",
        "unsigned" => "::std::os::raw::c_uint",
        "unsigned int" => "::std::os::raw::c_uint",
        "char" => "::std::os::raw::c_char",
        "unsigned char" => "::std::os::raw::c_uchar",

        "bool" => "c_bool",
        "size_t" => "Size_t",
    },

    TYPESIZEMAP => {
        IV => {
            1 => "i8",
            2 => "i16",
            4 => "i32",
            8 => "i64",
        },
        UV => {
            1 => "u8",
            2 => "u16",
            4 => "u32",
            8 => "u64",
        },
        NV => {
            4 => "f32",
            8 => "f64",
        },
    },

    RUST_TYPE => "Rust",
};

# Getters

sub map_type {
    my ($type) = @_;

    return $$type if ref $type eq RUST_TYPE;

    # working copy
    my $work = $type;

    # perl volatile and nullability markers mean nothing here
    $work =~ s/\b(?:VOL|NN|NULLOK)\b\s*//g;

    # canonicalize const placement, "const int" is the same as "int const"
    $work =~ s/const\s+(\w+)/$1 const/;

    (my $base_type, $work) = $work =~ /^((?:unsigned )?\w+)\s*(.*)/
        or die "unparsable type '$type'";

    my $rust_type = TYPEMAP->{$base_type}
        or die "unknown type $base_type (was: $type)";

    my $lim = 100;
    while ($work && --$lim > 0) {
        my $mode = "mut";
        if ($work =~ s/^const\s*//) {
            $mode = "const";
        }
        if ($work =~ s/^\*\s*//) {
            $rust_type = "*$mode $rust_type";
        }
    }
    die "unparsable type '$type'" if !$lim;

    return $rust_type;
}

sub map_type_size {
    my ($base, $size) = @_;
    return TYPESIZEMAP->{$base}{$size} // die "$base size $size type is missing";
}

sub const_value {
    my $name = shift;
    my $getter = Ouroboros->can($name) // die "constant $name is not available";
    return $getter->();
}

# Rust syntax

sub ty {
    my $type = shift;
    return bless \$type, RUST_TYPE;
}

sub indent {
    map "    $_", @_;
}

sub mod {
    my ($name, @items) = @_;
    return (
        "pub mod $name {",
        indent(@items),
        "}",
    );
}

sub type {
    my ($name, $ty) = @_;

    TYPEMAP->{$name} = $name;

    return "pub type $name = $ty;";
}

sub extern {
    my ($abi, @items) = @_;
    return (
        "extern \"$abi\" {",
        indent(@items),
        "}",
    );
}

sub _fn {
    my ($qual, $flags, $type, $name, @args) = @_;

    my $unnamed = $flags =~ /_/;
    my $genname = $flags =~ /!/;
    my $genpthx = $flags !~ /n/;

    $name = $flags =~ /p/ ? "Perl_$name" : $name;

    my @formal;

    push @formal, ($unnamed ? "" : "my_perl: ") . map_type("PerlInterpreter*")
        if $genpthx && $Config::Config{usemultiplicity};

    my $argname = "arg0";
    foreach my $arg (@args) {
        if ($arg eq "...") {
            push @formal, $arg;
        }
        else {
            my ($type, $name);

            if ($genname || $unnamed) {
                $type = $arg;
                $name = undef;
            }
            else {
                ($type, $name) = $arg =~ /(.*)\b(\w+)/;
                $name =~ s/^/a_/ if $name =~ /^(?:type|fn|unsafe|let|loop|ref)$/;
            }

            $name = $argname++ if !$name && $genname;

            my $rs_type = map_type($type);

            if ($unnamed) {
                push @formal, $rs_type;
            } else {
                push @formal, sprintf "%s: %s", $name, $rs_type;
            }
        }
    }

    my $returns = $type eq "void" ? "" : " -> " . map_type($type);

    local $" = ", ";

    return "$qual fn $name(@formal)$returns";
}

sub fn {
    return _fn("pub", @_) . ";";
}

sub extern_fn {
    my ($type, @args) = @_;

    return _fn('extern "C"', "_", $type, "", @args);
}

sub const {
    my ($name, $value) = @_;
    return "pub const $name: IV = $value;";
}

sub struct {
    my ($name, @fields) = @_;

    my @fields_rs;
    while (my ($name, $type) = splice @fields, 0, 2) {
        push @fields_rs, sprintf "%s: %s,", $name, map_type($type);
    }

    return (
        "#[repr(C)]",
        "pub struct $name {",
        indent(@fields_rs),
        "}"
    );
}

sub enum {
    my ($name, @items) = @_;
    die "non-empty enums are not supported yet" if @items;

    TYPEMAP->{$name} = $name;

    return "pub enum $name {}";
}

# Output blocks

sub perl_types {
    my $c = \%Config::Config;
    my $os = \%Ouroboros::Size;

    mod("types",
        "#![allow(non_camel_case_types)]",

        map(enum($_), @{STUB_TYPES()}),

        type("IV", map_type_size("IV", $c->{ivsize})),
        type("UV", map_type_size("UV", $c->{uvsize})),
        type("NV", map_type_size("NV", $c->{nvsize})),

        type("I8", map_type_size("IV", $c->{i8size})),
        type("U8", map_type_size("UV", $c->{u8size})),
        type("I16", map_type_size("IV", $c->{i16size})),
        type("U16", map_type_size("UV", $c->{u16size})),
        type("I32", map_type_size("IV", $c->{i32size})),
        type("U32", map_type_size("UV", $c->{u32size})),

        # assumes that these three types have the same size
        type("Size_t", map_type_size("UV", $c->{sizesize})),
        type("SSize_t", map_type_size("UV", $c->{sizesize})),
        type("STRLEN", map_type_size("UV", $c->{sizesize})),

        type("c_bool", map_type_size("UV", $os->{bool})),
        type("svtype", map_type_size("UV", $os->{svtype})),
        type("PADOFFSET", map_type_size("UV", $os->{PADOFFSET})),
        type("Optype", map_type_size("UV", $os->{Optype})),

        type("XSINIT_t", extern_fn("void")),
        type("SVCOMPARE_t", extern_fn("I32", "SV*", "SV*")),
        type("XSUBADDR_t", extern_fn("void", "CV*")),
        type("Perl_call_checker", extern_fn("OP*", "OP*", "GV*", "GV*")),
        type("Perl_check_t", extern_fn("OP*", "OP*")),

        struct("OuroborosStack", _data => ty sprintf("[u8; %d]", $os->{"struct ouroboros_stack"})),
    );
}

sub perl_macro {
    my ($flags, undef, $name) = @_;

    my $perl_name = $flags =~ /p/ ? "Perl_$name" : $name;

    my $pthx = $flags !~ /n/ && $Config::Config{usemultiplicity}
        ? "\$my_perl,"
        : "";

    "#[macro_export] macro_rules! $name { (\$my_perl:expr, \$( \$arg:expr ),*) => { $perl_name($pthx \$( \$arg ),*) }}";
}

sub perl_funcs {
    my $perl = shift;
    (
        extern("C",
            map(fn(@$_), @$perl)),
        map(perl_macro(@$_), @$perl),
    );
}

sub ouro_funcs {
    my $spec = shift;
    (
        extern("C",
            map(fn(@$_), @{$spec->{fn}})),
        map(perl_macro(@$_), @{$spec->{fn}}),
    );
}

sub ouro_consts {
    my $spec = shift;
    mod("consts",
        "#![allow(non_upper_case_globals)]",
        "use types::*;",
        map(const($_, const_value($_)), map $_->[1], @{$spec->{const}}));
}

# Read libouroboros.txt

my %ouro;
foreach (read_file(OURO_TXT_PATH, chomp => 1)) {
    next if !$_ || /^#/;
    my ($kind, @def) = split /\t/;
    push @{$ouro{$kind}}, [ "!", @def ];
}

# Read embed.fnc
my @perl;
{
    my $opts = Config::Perl::V::myconfig()->{options};
    my @lines = read_file(EMBED_FNC_PATH, chomp => 1);
    my @scope = (1);
    while (defined ($_ = shift @lines)) {
        while (@lines && s/\\$/shift @lines/e) {}

        next if !$_ || /^:/;

        s/#\s*ifdef\s+(\w+)/#if defined($1)/;
        s/#\s*ifndef\s+(\w+)/#if !defined($1)/;

        if (my ($pp, $args) = /^#\s*(\w+)(.*)/) {
            if ($pp eq "if") {
                $args =~ s/defined\s*\([\w+]\)/\$opts->{$1}/;
                unshift @scope, eval $args && $scope[0];
            }
            elsif ($pp eq "endif") {
                die "unmatched #endif" if @scope < 2;
                shift @scope;
            }
            elsif ($pp eq "else") {
                $scope[0] = !$scope[0];
            }
            else {
                die "unknown directive $pp";
            }
            next;
        }

        next unless $scope[0];

        my ($flags, $type, $name, @args) = split /\s*\|\s*/;

        ($type, @args) = map s/^\s+//r =~ s/\s+$//r, ($type, @args);

        next unless
            # public
            $flags =~ /A/ &&
            # documented
            $flags =~ /d/ &&
            # not a macro
            $flags !~ /m/ &&
            # not for backwards compat
            $flags !~ /b/
            # not experimental
            && $flags !~ /M/;

        # va_list is useless in rust anyway
        next if grep /\bva_list\b/, $type, @args;

        push @perl, [ $flags, $type, $name, @args ];
    }
}

my @lines = (
    perl_types(),
    "",
    "#[macro_use]",
    mod("funcs",
        "use types::*;",
        perl_funcs(\@perl),
        ouro_funcs(\%ouro)),
    "",
    ouro_consts(\%ouro),
);

open my $targ, ">", catfile(OUT_DIR, OUT_NAME);
$targ->print(map "$_\n", @lines);
