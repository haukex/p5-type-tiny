package Type::Tiny;

use 5.006001;
use strict;
use warnings;

BEGIN {
	if ($] < 5.008) { require Devel::TypeTiny::Perl56Compat };
}

BEGIN {
	$Type::Tiny::AUTHORITY = 'cpan:TOBYINK';
	$Type::Tiny::VERSION   = '0.023_01';
}

use Eval::TypeTiny ();
use Scalar::Util qw( blessed weaken refaddr isweak );
use Types::TypeTiny ();

sub _croak ($;@) { require Type::Exception; goto \&Type::Exception::croak }

sub _swap { $_[2] ? @_[1,0] : @_[0,1] }

BEGIN {
	($] > 5.010001)
		? eval q{ sub SUPPORT_SMARTMATCH () { !!0 } }
		: eval q{ sub SUPPORT_SMARTMATCH () { !!1 } }
}

use overload
	q("")      => sub { caller =~ m{^(Moo::HandleMoose|Sub::Quote)} ? overload::StrVal($_[0]) : $_[0]->display_name },
	q(bool)    => sub { 1 },
	q(&{})     => "_overload_coderef",
	q(+)       => sub { $_[2] ? $_[1]->plus_coercions($_[0]) : $_[0]->plus_fallback_coercions($_[1]) },
	q(|)       => sub { my @tc = _swap @_; require Type::Tiny::Union; "Type::Tiny::Union"->new(type_constraints => \@tc) },
	q(&)       => sub { my @tc = _swap @_; require Type::Tiny::Intersection; "Type::Tiny::Intersection"->new(type_constraints => \@tc) },
	q(~)       => sub { shift->complementary_type },
	q(==)      => sub { $_[0]->equals($_[1]) },
	q(<)       => sub { my $m = $_[0]->can('is_subtype_of'); $m->(_swap @_) },
	q(>)       => sub { my $m = $_[0]->can('is_subtype_of'); $m->(reverse _swap @_) },
	q(<=)      => sub { my $m = $_[0]->can('is_a_type_of');  $m->(_swap @_) },
	q(>=)      => sub { my $m = $_[0]->can('is_a_type_of');  $m->(reverse _swap @_) },
	q(eq)      => sub { $_[2] ? ("$_[1]" eq "$_[0]") : ("$_[0]" eq "$_[1]") },
	q(cmp)     => sub { $_[2] ? ("$_[1]" cmp "$_[0]") : ("$_[0]" cmp "$_[1]") },
	fallback   => 1,
;
BEGIN {
	overload->import(q(~~) => sub { $_[0]->check($_[1]) })
		if Type::Tiny::SUPPORT_SMARTMATCH;
}

sub _overload_coderef
{
	my $self = shift;
	$self->message unless exists $self->{message};
	
#	if ($self->has_parent && $self->_is_null_constraint)
#	{
#		$self->{_overload_coderef} ||= $self->parent->_overload_coderef;
#	}
#	els
	if ($self->{_default_message} && "Sub::Quote"->can("quote_sub") && $self->can_be_inlined)
	{
		$self->{_overload_coderef} = Sub::Quote::quote_sub($self->inline_assert('$_[0]'))
			if !$self->{_overload_coderef} || !$self->{_sub_quoted}++;
	}
	else
	{
		$self->{_overload_coderef} ||= sub { $self->assert_return(@_) };
	}
	
	$self->{_overload_coderef};
}

our %ALL_TYPES;

my $QFS;
my $uniq = 1;
sub new
{
	my $class  = shift;
	my %params = (@_==1) ? %{$_[0]} : @_;
	
	if (exists $params{parent})
	{
		$params{parent} = ref($params{parent}) =~ /^Type::Tiny\b/
			? $params{parent}
			: Types::TypeTiny::to_TypeTiny($params{parent});
		
		_croak "Parent must be an instance of %s", __PACKAGE__
			unless blessed($params{parent}) && $params{parent}->isa(__PACKAGE__);
	}
	
	$params{name} = "__ANON__" unless exists $params{name};
	$params{uniq} = $uniq++;
	
	if ($params{name} ne "__ANON__")
	{
		# First try a fast ASCII-only expression, but fall back to Unicode
		$params{name} =~ /^[A-Z][A-Za-z0-9_]+$/sm
			or eval q( use 5.008; $params{name} =~ /^\p{Lu}[\p{L}0-9_]+$/sm )
			or _croak '"%s" is not a valid type name', $params{name};
	}
	
	if (exists $params{coercion} and !ref $params{coercion} and $params{coercion})
	{
		$params{parent}->has_coercion
			or _croak "coercion => 1 requires type to have a direct parent with a coercion";
		
		$params{coercion} = $params{parent}->coercion;
	}
	
	if (!exists $params{inlined}
	and exists $params{constraint}
	and ( !exists $params{parent} or $params{parent}->can_be_inlined )
	and $QFS ||= "Sub::Quote"->can("quoted_from_sub"))
	{
		my (undef, $perlstring, $captures) = @{ $QFS->($params{constraint}) || [] };
		
		$params{inlined} = sub {
			my ($self, $var) = @_;
			my $code = Sub::Quote::inlinify(
				$var eq q($_) ? $perlstring : "local \$_ = $var; $perlstring",
				$var,
			);
			$code = sprintf('%s and %s', $self->parent->inline_check($var), $code) if $self->has_parent;
			return $code;
		} if $perlstring && !$captures;
	}
	
	my $self = bless \%params, $class;
	
	unless ($params{tmp})
	{
		$Moo::HandleMoose::TYPE_MAP{overload::StrVal($self)} = sub { $self };
#			if $self->has_library && !$self->is_anon;
		
		$ALL_TYPES{ $self->{uniq} } = $self;
		weaken($ALL_TYPES{ $self->{uniq} });
	}
	
	$self->{type_constraints} ||= undef;
	
	return $self;
}

sub _clone
{
	my $self = shift;
	my %opts;
	$opts{$_} = $self->{$_} for qw< name display_name message >;
	$self->create_child_type(%opts);
}

sub _dd
{
	require B;
	
	my $value = @_ ? $_[0] : $_;
	
	!defined $value      ? 'Undef' :
	!ref $value          ? sprintf('Value %s', B::perlstring($value)) :
	do {
		require Data::Dumper;
		local $Data::Dumper::Indent   = 0;
		local $Data::Dumper::Useqq    = 1;
		local $Data::Dumper::Terse    = 1;
		local $Data::Dumper::Sortkeys = 1;
		local $Data::Dumper::Maxdepth = 2;
		my $str = Data::Dumper::Dumper($value);
		$str = substr($str, 0, 60).'...'.substr($str, -1, 1)
			if length($str) >= 72;
		"Reference $str";
	}
}

sub _loose_to_TypeTiny
{
	map +(
		ref($_)
			? Types::TypeTiny::to_TypeTiny($_)
			: do { require Type::Utils; Type::Utils::dwim_type($_) }
	), @_;
}

sub name                     { $_[0]{name} }
sub display_name             { $_[0]{display_name}   ||= $_[0]->_build_display_name }
sub parent                   { $_[0]{parent} }
sub constraint               { $_[0]{constraint}     ||= $_[0]->_build_constraint }
sub compiled_check           { $_[0]{compiled_type_constraint} ||= $_[0]->_build_compiled_check }
sub coercion                 { $_[0]{coercion}       ||= $_[0]->_build_coercion }
sub message                  { $_[0]{message} }
sub library                  { $_[0]{library} }
sub inlined                  { $_[0]{inlined} }
sub constraint_generator     { $_[0]{constraint_generator} }
sub inline_generator         { $_[0]{inline_generator} }
sub name_generator           { $_[0]{name_generator} ||= $_[0]->_build_name_generator }
sub coercion_generator       { $_[0]{coercion_generator} }
sub parameters               { $_[0]{parameters} }
sub moose_type               { $_[0]{moose_type}     ||= $_[0]->_build_moose_type }
sub mouse_type               { $_[0]{mouse_type}     ||= $_[0]->_build_mouse_type }
sub deep_explanation         { $_[0]{deep_explanation} }

sub has_parent               { exists $_[0]{parent} }
sub has_library              { exists $_[0]{library} }
sub has_coercion             { exists $_[0]{coercion} and !!@{ $_[0]{coercion}->type_coercion_map } }
sub has_inlined              { exists $_[0]{inlined} }
sub has_constraint_generator { exists $_[0]{constraint_generator} }
sub has_inline_generator     { exists $_[0]{inline_generator} }
sub has_coercion_generator   { exists $_[0]{coercion_generator} }
sub has_parameters           { exists $_[0]{parameters} }
sub has_message              { defined $_[0]{message} }
sub has_deep_explanation     { exists $_[0]{deep_explanation} }

sub _default_message         { $_[0]{_default_message} ||= $_[0]->_build_default_message }

sub _assert_coercion
{
	my $self = shift;
	_croak "No coercion for this type constraint"
		unless $self->has_coercion && @{$self->coercion->type_coercion_map};
	return $self->coercion;
}

my $null_constraint = sub { !!1 };

sub _build_display_name
{
	shift->name;
}

sub _build_constraint
{
	return $null_constraint;
}

sub _is_null_constraint
{
	shift->constraint == $null_constraint;
}

sub _build_coercion
{
	require Type::Coercion;
	my $self = shift;
	my %opts = (type_constraint => $self);
	$opts{display_name} = "to_$self" unless $self->is_anon;
	return "Type::Coercion"->new(%opts);
}

sub _build_default_message
{
	my $self = shift;
	return sub { sprintf '%s did not pass type constraint', _dd($_[0]) } if "$self" eq "__ANON__";
	my $name = "$self";
	return sub { sprintf '%s did not pass type constraint "%s"', _dd($_[0]), $name };
}

sub _build_name_generator
{
	my $self = shift;
	return sub {
		my ($s, @a) = @_;
		sprintf('%s[%s]', $s, join q[,], @a);
	};
}

sub _build_compiled_check
{
	my $self = shift;
	
	if ($self->_is_null_constraint and $self->has_parent)
	{
		return $self->parent->compiled_check;
	}
	
	if ($INC{'Mouse/Util.pm'} and Mouse::Util::MOUSE_XS())
	{
		require Mouse::Util::TypeConstraints;
		
		if ($self->{_is_core})
		{
			my $xs = "Mouse::Util::TypeConstraints"->can($self->name);
			return $xs if $xs;
		}
		elsif ($self->is_parameterized and $self->has_parent
		and $self->parent->{_is_core} and $self->parent->name =~ /^(ArrayRef|HashRef|Maybe)$/)
		{
			my $xs = "Mouse::Util::TypeConstraints"->can("_parameterize_".$self->parent->name."_for");
			return $xs->($self->parameters->[0]) if $xs;
		}
	}
	
	return Eval::TypeTiny::eval_closure(
		source      => sprintf('sub ($) { %s }', $self->inline_check('$_[0]')),
		description => sprintf("compiled check '%s'", $self),
	) if $self->can_be_inlined;
	
	my @constraints;
	push @constraints, $self->parent->compiled_check if $self->has_parent;
	push @constraints, $self->constraint if !$self->_is_null_constraint;
	return $null_constraint unless @constraints;
	
	return sub ($)
	{
		local $_ = $_[0];
		for my $c (@constraints)
		{
			return unless $c->(@_);
		}
		return !!1;
	};
}

sub equals
{
	my ($self, $other) = _loose_to_TypeTiny(@_);
	return unless blessed($self)  && $self->isa("Type::Tiny");
	return unless blessed($other) && $other->isa("Type::Tiny");
	
	return !!1 if refaddr($self) == refaddr($other);
	
	return !!1 if $self->has_parent  && $self->_is_null_constraint  && $self->parent==$other;
	return !!1 if $other->has_parent && $other->_is_null_constraint && $other->parent==$self;
	
	return !!1 if refaddr($self->compiled_check) == refaddr($other->compiled_check);
	
	return $self->qualified_name eq $other->qualified_name
		if $self->has_library && !$self->is_anon && $other->has_library && !$other->is_anon;
	
	return $self->inline_check('$x') eq $other->inline_check('$x')
		if $self->can_be_inlined && $other->can_be_inlined;
	
	return;
}

sub is_subtype_of
{
	my ($self, $other) = _loose_to_TypeTiny(@_);
	return unless blessed($self)  && $self->isa("Type::Tiny");
	return unless blessed($other) && $other->isa("Type::Tiny");

#	my $this = $self;
#	while (my $parent = $this->parent)
#	{
#		return !!1 if $parent->equals($other);
#		$this = $parent;
#	}
#	return;

	return unless $self->has_parent;
	$self->parent->equals($other) or $self->parent->is_subtype_of($other);
}

sub is_supertype_of
{
	my ($self, $other) = _loose_to_TypeTiny(@_);
	return unless blessed($self)  && $self->isa("Type::Tiny");
	return unless blessed($other) && $other->isa("Type::Tiny");
	
	$other->is_subtype_of($self);
}

sub is_a_type_of
{
	my ($self, $other) = _loose_to_TypeTiny(@_);
	return unless blessed($self)  && $self->isa("Type::Tiny");
	return unless blessed($other) && $other->isa("Type::Tiny");
	
	$self->equals($other) or $self->is_subtype_of($other);
}

sub strictly_equals
{
	my ($self, $other) = _loose_to_TypeTiny(@_);
	return unless blessed($self)  && $self->isa("Type::Tiny");
	return unless blessed($other) && $other->isa("Type::Tiny");
	$self->{uniq} == $other->{uniq};
}

sub is_strictly_subtype_of
{
	my ($self, $other) = _loose_to_TypeTiny(@_);
	return unless blessed($self)  && $self->isa("Type::Tiny");
	return unless blessed($other) && $other->isa("Type::Tiny");

#	my $this = $self;
#	while (my $parent = $this->parent)
#	{
#		return !!1 if $parent->strictly_equals($other);
#		$this = $parent;
#	}
#	return;

	return unless $self->has_parent;
	$self->parent->strictly_equals($other) or $self->parent->is_strictly_subtype_of($other);
}

sub is_strictly_supertype_of
{
	my ($self, $other) = _loose_to_TypeTiny(@_);
	return unless blessed($self)  && $self->isa("Type::Tiny");
	return unless blessed($other) && $other->isa("Type::Tiny");
	
	$other->is_strictly_subtype_of($self);
}

sub is_strictly_a_type_of
{
	my ($self, $other) = _loose_to_TypeTiny(@_);
	return unless blessed($self)  && $self->isa("Type::Tiny");
	return unless blessed($other) && $other->isa("Type::Tiny");
	
	$self->strictly_equals($other) or $self->is_strictly_subtype_of($other);
}

sub qualified_name
{
	my $self = shift;
	(exists $self->{library} and $self->name ne "__ANON__")
		? "$self->{library}::$self->{name}"
		: $self->{name};
}

sub is_anon
{
	my $self = shift;
	$self->name eq "__ANON__";
}

sub parents
{
	my $self = shift;
	return unless $self->has_parent;
	return ($self->parent, $self->parent->parents);
}

sub check
{
	my $self = shift;
	($self->{compiled_type_constraint} ||= $self->_build_compiled_check)->(@_);
}

sub _strict_check
{
	my $self = shift;
	local $_ = $_[0];

	my @constraints =
		reverse
		map  { $_->constraint }
		grep { not $_->_is_null_constraint }
		($self, $self->parents);
	
	for my $c (@constraints)
	{
		return unless $c->(@_);
	}
	
	return !!1;
}

sub get_message
{
	my $self = shift;
	local $_ = $_[0];
	$self->has_message
		? $self->message->(@_)
		: $self->_default_message->(@_);
}

sub validate
{
	my $self = shift;
	
	return undef if ($self->{compiled_type_constraint} ||= $self->_build_compiled_check)->(@_);
	
	local $_ = $_[0];
	return $self->get_message(@_);
}

sub assert_valid
{
	my $self = shift;
	
	return !!1 if ($self->{compiled_type_constraint} ||= $self->_build_compiled_check)->(@_);
	
	local $_ = $_[0];
	$self->_failed_check("$self", $_);
}

sub assert_return
{
	my $self = shift;
	
	return $_[0] if ($self->{compiled_type_constraint} ||= $self->_build_compiled_check)->(@_);
	
	local $_ = $_[0];
	$self->_failed_check("$self", $_);
}

sub can_be_inlined
{
	my $self = shift;
	return $self->parent->can_be_inlined
		if $self->has_parent && $self->_is_null_constraint;
	return !!1
		if !$self->has_parent && $self->_is_null_constraint;
	return $self->has_inlined;
}

sub inline_check
{
	my $self = shift;
	_croak 'Cannot inline type constraint check for "%s"', $self
		unless $self->can_be_inlined;
	
	return $self->parent->inline_check(@_)
		if $self->has_parent && $self->_is_null_constraint;
	return '(!!1)'
		if !$self->has_parent && $self->_is_null_constraint;
	
	local $_ = $_[0];
	my @r = $self->inlined->($self, @_);
	if (@r and not defined $r[0])
	{
		_croak 'Inlining type constraint check for "%s" returned undef!', $self
			unless $self->has_parent;
		$r[0] = $self->parent->inline_check(@_);
	}
	my $r = join " && " => map { /[;{}]/ ? "do { $_ }" : "($_)" } @r;
	return @r==1 ? $r : "($r)";
}

sub inline_assert
{
	require B;
	my $self = shift;
	my $varname = $_[0];
	my $code = sprintf(
		q[do { no warnings "void"; %s ? %s : Type::Tiny::_failed_check(%d, %s, %s) };],
		$self->inline_check(@_),
		$varname,
		$self->{uniq},
		B::perlstring("$self"),
		$varname,
	);
	return $code;
}

sub _failed_check
{
	require Type::Exception::Assertion;
	
	my ($self, $name, $value, %attrs) = @_;
	$self = $ALL_TYPES{$self} unless ref $self;
	
	my $exception_class = delete($attrs{exception_class}) || "Type::Exception::Assertion";
	
	if ($self)
	{
		$exception_class->throw(
			message => $self->get_message($value),
			type    => $self,
			value   => $value,
			%attrs,
		);
	}
	else
	{
		$exception_class->throw(
			message => sprintf('%s did not pass type constraint "%s"', _dd($value), $name),
			value   => $value,
			%attrs,
		);
	}
}

sub coerce
{
	my $self = shift;
	$self->_assert_coercion->coerce(@_);
}

sub assert_coerce
{
	my $self = shift;
	$self->_assert_coercion->assert_coerce(@_);
}

sub is_parameterizable
{
	shift->has_constraint_generator;
}

sub is_parameterized
{
	shift->has_parameters;
}

my %param_cache;
sub parameterize
{
	my $self = shift;
	return $self unless @_;
	$self->is_parameterizable
		or _croak "Type '%s' does not accept parameters", "$self";
	
	@_ = map Types::TypeTiny::to_TypeTiny($_), @_;
	
	# Generate a key for caching parameterized type constraints,
	# but only if all the parameters are strings or type constraints.
	my $key;
	if ( not grep(ref($_) && !Types::TypeTiny::TypeTiny->check($_), @_) )
	{
		require B;
		$key = join ":", map(Types::TypeTiny::TypeTiny->check($_) ? $_->{uniq} : B::perlstring($_), $self, @_);
	}
	
	return $param_cache{$key} if defined $key && defined $param_cache{$key};
	
	local $Type::Tiny::parameterize_type = $self;
	local $_ = $_[0];
	my $P;
	
	my $constraint = $self->constraint_generator->(@_);
	
	if (Types::TypeTiny::TypeTiny->check($constraint))
	{
		$P = $constraint;
	}
	else
	{
		my %options = (
			constraint   => $constraint,
			display_name => $self->name_generator->($self, @_),
			parameters   => [@_],
		);
		$options{inlined} = $self->inline_generator->(@_)
			if $self->has_inline_generator;
		exists $options{$_} && !defined $options{$_} && delete $options{$_}
			for keys %options;
		
		$P = $self->create_child_type(%options);
		
		my $coercion;
		$coercion = $self->coercion_generator->($self, $P, @_)
			if $self->has_coercion_generator;
		$P->coercion->add_type_coercions( @{$coercion->type_coercion_map} )
			if $coercion;
	}
	
	if (defined $key)
	{
		$param_cache{$key} = $P;
		weaken($param_cache{$key});
	}
	
	return $P;
}

sub child_type_class
{
	__PACKAGE__;
}

sub create_child_type
{
	my $self = shift;
	return $self->child_type_class->new(parent => $self, @_);
}

sub complementary_type
{
	my $self = shift;
	my $r    = ($self->{complementary_type} ||= $self->_build_complementary_type);
	weaken($self->{complementary_type}) unless isweak($self->{complementary_type});
	return $r;
}

sub _build_complementary_type
{
	my $self = shift;
	my %opts = (
		constraint   => sub { not $self->check($_) },
		display_name => sprintf("~%s", $self),
	);
	$opts{display_name} =~ s/^\~{2}//;
	$opts{inlined} = sub { shift; "not(".$self->inline_check(@_).")" }
		if $self->can_be_inlined;
	return "Type::Tiny"->new(%opts);
}

sub _instantiate_moose_type
{
	my $self = shift;
	my %opts = @_;
	require Moose::Meta::TypeConstraint;
	return "Moose::Meta::TypeConstraint"->new(%opts);
}

sub _build_moose_type
{
	my $self = shift;
	
	my $r;
	if ($self->{_is_core})
	{
		require Moose::Util::TypeConstraints;
		$r = Moose::Util::TypeConstraints::find_type_constraint($self->name);
		$r->{"Types::TypeTiny::to_TypeTiny"} = $self;
		Scalar::Util::weaken($r->{"Types::TypeTiny::to_TypeTiny"});
	}
	else
	{
		my %opts;
		$opts{name}       = $self->qualified_name     if $self->has_library && !$self->is_anon;
		$opts{parent}     = $self->parent->moose_type if $self->has_parent;
		$opts{constraint} = $self->constraint         unless $self->_is_null_constraint;
		$opts{message}    = $self->message            if $self->has_message;
		$opts{inlined}    = $self->inlined            if $self->has_inlined;
		
		$r = $self->_instantiate_moose_type(%opts);
		$r->{"Types::TypeTiny::to_TypeTiny"} = $self;
		Scalar::Util::weaken($r->{"Types::TypeTiny::to_TypeTiny"});
		$self->{moose_type} = $r;  # prevent recursion
		$r->coercion($self->coercion->moose_coercion) if $self->has_coercion;
	}
		
	return $r;
}

sub _build_mouse_type
{
	my $self = shift;
	
	my %options;
	$options{name}       = $self->qualified_name     if $self->has_library && !$self->is_anon;
	$options{parent}     = $self->parent->mouse_type if $self->has_parent;
	$options{constraint} = $self->constraint         unless $self->_is_null_constraint;
	$options{message}    = $self->message            if $self->has_message;
		
	require Mouse::Meta::TypeConstraint;
	my $r = "Mouse::Meta::TypeConstraint"->new(%options);
	
	$self->{mouse_type} = $r;  # prevent recursion
	$r->_add_type_coercions(
		$self->coercion->freeze->_codelike_type_coercion_map('mouse_type')
	) if $self->has_coercion;
	
	return $r;
}

sub plus_coercions
{
	my $self = shift;
	
	my @more = (@_==1 && blessed($_[0]) && $_[0]->can('type_coercion_map'))
		? @{ $_[0]->type_coercion_map }
		: (@_==1 && ref $_[0]) ? @{$_[0]} : @_;
	
	my $new = $self->_clone;
	$new->coercion->add_type_coercions(
		@more,
		@{$self->coercion->type_coercion_map},
	);
	return $new;
}

sub plus_fallback_coercions
{
	my $self = shift;
	
	my @more = (@_==1 && blessed($_[0]) && $_[0]->can('type_coercion_map'))
		? @{ $_[0]->type_coercion_map }
		: (@_==1 && ref $_[0]) ? @{$_[0]} : @_;
	
	my $new = $self->_clone;
	$new->coercion->add_type_coercions(
		@{$self->coercion->type_coercion_map},
		@more,
	);
	return $new;
}

sub minus_coercions
{
	my $self = shift;
	
	my @not = (@_==1 && blessed($_[0]) && $_[0]->can('type_coercion_map'))
		? grep(blessed($_)&&$_->isa("Type::Tiny"), @{ $_[0]->type_coercion_map })
		: (@_==1 && ref $_[0]) ? @{$_[0]} : @_;
	
	my @keep;
	my $c = $self->coercion->type_coercion_map;
	for (my $i = 0; $i <= $#$c; $i += 2)
	{
		my $keep_this = 1;
		NOT: for my $n (@not)
		{
			if ($c->[$i] == $n)
			{
				$keep_this = 0;
				last NOT;
			}
		}
		
		push @keep, $c->[$i], $c->[$i+1] if $keep_this;
	}

	my $new = $self->_clone;
	$new->coercion->add_type_coercions(@keep);
	return $new;
}

sub no_coercions
{
	shift->_clone;
}

sub isa
{
	my $self = shift;
	
	if ($INC{"Moose.pm"} and ref($self))
	{
		return !!1                       if $_[0] eq 'Moose::Meta::TypeConstraint';
		return $self->is_parameterized   if $_[0] eq 'Moose::Meta::TypeConstraint::Parameterized';
		return $self->is_parameterizable if $_[0] eq 'Moose::Meta::TypeConstraint::Parameterizable';
	}
	
	if ($INC{"Moose.pm"} and ref($self) and $_[0] =~ /^Moose/ and my $r = $self->moose_type->isa(@_))
	{
		return $r;
	}

	if ($INC{"Mouse.pm"} and ref($self) and $_[0] eq 'Mouse::Meta::TypeConstraint')
	{
		return !!1;
	}

	$self->SUPER::isa(@_);
}

sub can
{
	my $self = shift;
	
	return !!0 if $_[0] eq 'type_parameter' && blessed($_[0]) && $_[0]->has_parameters;
	
	my $can = $self->SUPER::can(@_);
	return $can if $can;
	
	if ($INC{"Moose.pm"} and ref($self) and my $method = $self->moose_type->can(@_))
	{
		return sub { $method->(shift->moose_type, @_) };
	}
	
	return;
}

sub AUTOLOAD
{
	my $self = shift;
	my ($m) = (our $AUTOLOAD =~ /::(\w+)$/);
	return if $m eq 'DESTROY';
	
	if ($INC{"Moose.pm"} and ref($self) and my $method = $self->moose_type->can($m))
	{
		return $method->($self->moose_type, @_);
	}
	
	_croak q[Can't locate object method "%s" via package "%s"], $m, ref($self)||$self;
}

sub DOES
{
	my $self = shift;
	
	return !!1 if  ref($self) && $_[0] =~ m{^ Type::API::Constraint (?: ::Coercible | ::Inlinable )? $}x;
	return !!1 if !ref($self) && $_[0] eq 'Type::API::Constraint::Constructor';
	
	"UNIVERSAL"->can("DOES") ? $self->SUPER::DOES(@_) : $self->isa(@_);
}

# fill out Moose-compatible API
sub inline_environment         { +{} }
sub _inline_check              { shift->inline_check(@_) }
sub _compiled_type_constraint  { shift->compiled_check(@_) }
sub meta                       { _croak("Not really a Moose::Meta::TypeConstraint. Sorry!") }
sub compile_type_constraint    { shift->compiled_check }
sub _actually_compile_type_constraint   { shift->_build_compiled_check }
sub hand_optimized_type_constraint      { shift->{hand_optimized_type_constraint} }
sub has_hand_optimized_type_constraint  { exists(shift->{hand_optimized_type_constraint}) }
sub type_parameter             { my @p = @{ shift->parameters || [] }; @p==1 ? $p[0] : @p }

# some stuff for Mouse-compatible API
sub __is_parameterized         { shift->is_parameterized(@_) }
sub _add_type_coercions        { shift->coercion->add_type_coercions(@_) };
sub _as_string                 { shift->qualified_name(@_) }
sub _compiled_type_coercion    { shift->coercion->compiled_coercion(@_) };
sub _identity                  { refaddr(shift) };
sub _unite                     { require Type::Tiny::Union; "Type::Tiny::Union"->new(type_constraints => \@_) };

# Hooks for Type::Tie
sub TIESCALAR  { require Type::Tie; unshift @_, 'Type::Tie::SCALAR'; goto \&Type::Tie::SCALAR::TIESCALAR };
sub TIEARRAY   { require Type::Tie; unshift @_, 'Type::Tie::ARRAY';  goto \&Type::Tie::SCALAR::TIEARRAY };
sub TIEHASH    { require Type::Tie; unshift @_, 'Type::Tie::HASH';   goto \&Type::Tie::SCALAR::TIEHASH };

1;

__END__

=pod

=encoding utf-8

=for stopwords Moo(se)-compatible MooseX MouseX MooX Moose-compat

=head1 NAME

Type::Tiny - tiny, yet Moo(se)-compatible type constraint

=head1 SYNOPSIS

   use Scalar::Util qw(looks_like_number);
   use Type::Tiny;
   
   my $NUM = "Type::Tiny"->new(
      name       => "Number",
      constraint => sub { looks_like_number($_) },
      message    => sub { "$_ ain't a number" },
   );
   
   package Ermintrude {
      use Moo;
      has favourite_number => (is => "ro", isa => $NUM);
   }
   
   package Bullwinkle {
      use Moose;
      has favourite_number => (is => "ro", isa => $NUM);
   }
   
   package Maisy {
      use Mouse;
      has favourite_number => (is => "ro", isa => $NUM);
   }

=head1 DESCRIPTION

L<Type::Tiny> is a tiny class for creating Moose-like type constraint
objects which are compatible with Moo, Moose and Mouse.

Maybe now we won't need to have separate MooseX, MouseX and MooX versions
of everything? We can but hope...

This documents the internals of L<Type::Tiny>. L<Type::Tiny::Manual> is
a better starting place if you're new.

=head2 Constructor

=over

=item C<< new(%attributes) >>

Moose-style constructor function.

=back

=head2 Attributes

=over

=item C<< name >>

The name of the type constraint. These need to conform to certain naming
rules (they must begin with an uppercase letter and continue using only
letters, digits 0-9 and underscores).

Optional; if not supplied will be an anonymous type constraint.

=item C<< display_name >>

A name to display for the type constraint when stringified. These don't
have to conform to any naming rules. Optional; a default name will be
calculated from the C<name>.

=item C<< parent >>

Optional attribute; parent type constraint. For example, an "Integer"
type constraint might have a parent "Number".

If provided, must be a Type::Tiny object.

=item C<< constraint >>

Coderef to validate a value (C<< $_ >>) against the type constraint. The
coderef will not be called unless the value is known to pass any parent
type constraint.

Defaults to C<< sub { 1 } >> - i.e. a coderef that passes all values.

=item C<< compiled_check >>

Coderef to validate a value (C<< $_[0] >>) against the type constraint.
This coderef is expected to also handle all validation for the parent
type constraints.

The general point of this attribute is that you should not set it, and
rely on the lazily-built default. Type::Tiny will usually generate a
pretty fast coderef.

=item C<< message >>

Coderef that returns an error message when C<< $_ >> does not validate
against the type constraint. Optional (there's a vaguely sensible default.)

=item C<< inlined >>

A coderef which returns a string of Perl code suitable for inlining this
type. Optional.

If C<constraint> (above) is a coderef generated via L<Sub::Quote>, then
Type::Tiny I<may> be able to automatically generate C<inlined> for you.

=item C<< library >>

The package name of the type library this type is associated with.
Optional. Informational only: setting this attribute does not install
the type into the package.

=item C<< coercion >>

A L<Type::Coercion> object associated with this type.

Generally speaking this attribute should not be passed to the constructor;
you should rely on the default lazily-built coercion object.

You may pass C<< coercion => 1 >> to the constructor to inherit coercions
from the constraint's parent. (This requires the parent constraint to have
a coercion.)

=item C<< complementary_type >>

A complementary type for this type. For example, the complementary type
for an integer type would be all things that are not integers, including
floating point numbers, but also alphabetic strings, arrayrefs, filehandles,
etc.

Generally speaking this attribute should not be passed to the constructor;
you should rely on the default lazily-built complementary type.

=item C<< moose_type >>, C<< mouse_type >>

Objects equivalent to this type constraint, but as a
L<Moose::Meta::TypeConstraint> or L<Mouse::Meta::TypeConstraint>.

Generally speaking this attribute should not be passed to the constructor;
you should rely on the default lazily-built objects.

It should rarely be necessary to obtain a L<Moose::Meta::TypeConstraint>
object from L<Type::Tiny> because the L<Type::Tiny> object itself should
be usable pretty much anywhere a L<Moose::Meta::TypeConstraint> is expected.

=back

The following additional attributes are used for parameterizable (e.g.
C<ArrayRef>) and parameterized (e.g. C<< ArrayRef[Int] >>) type
constraints. Unlike Moose, these aren't handled by separate subclasses.

=over

=item C<< parameters >>

In parameterized types, returns an arrayref of the parameters.

=item C<< name_generator >>

A coderef which generates a new display_name based on parameters.
Optional; the default is reasonable.

=item C<< constraint_generator >>

Coderef that generates a new constraint coderef based on parameters.
Optional; providing a generator makes this type into a parameterizable
type constraint.

=item C<< inline_generator >>

A coderef which generates a new inlining coderef based on parameters.

=item C<< coercion_generator >>

A coderef which generates a new L<Type::Coercion> object based on parameters.

=item C<< deep_explanation >>

This API is not finalized. Coderef used by L<Type::Exception::Assertion> to
peek inside parameterized types and figure out why a value doesn't pass the
constraint.

=back

=head2 Methods

=over

=item C<has_parent>, C<has_library>, C<has_inlined>, C<has_constraint_generator>, C<has_inline_generator>, C<has_coercion_generator>, C<has_parameters>, C<has_message>, C<has_deep_explanation>

Predicate methods.

=item C<has_coercion>

Predicate method with a little extra DWIM. Returns false if the coercion is
a no-op.

=item C<< is_anon >>

Returns true iff the type constraint does not have a C<name>.

=item C<< is_parameterized >>, C<< is_parameterizable >>

Indicates whether a type has been parameterized (e.g. C<< ArrayRef[Int] >>)
or could potentially be (e.g. C<< ArrayRef >>).

=item C<< qualified_name >>

For non-anonymous type constraints that have a library, returns a qualified
C<< "Library::Type" >> sort of name. Otherwise, returns the same as C<name>.

=item C<< parents >>

Returns a list of all this type constraint's ancestor constraints. For
example, if called on the C<Str> type constraint would return the list
C<< (Value, Defined, Item, Any) >>.

B<< Due to a historical misunderstanding, this differs from the Moose
implementation of the C<parents> method. In Moose, C<parents> only returns the
immediate parent type constraints, and because type constraints only have
one immediate parent, this is effectively an alias for C<parent>. The
extension module L<MooseX::Meta::TypeConstraint::Intersection> is the only
place where multiple type constraints are returned; and they are returned
as an arrayref in violation of the base class' documentation. I'm keeping
my behaviour as it seems more useful. >>

=item C<< equals($other) >>, C<< is_subtype_of($other) >>, C<< is_supertype_of($other) >>, C<< is_a_type_of($other) >>

Compare two types. See L<Moose::Meta::TypeConstraint> for what these all mean.
(OK, Moose doesn't define C<is_supertype_of>, but you get the idea, right?)

Note that these have a slightly DWIM side to them. If you create two
L<Type::Tiny::Class> objects which test the same class, they're considered
equal. And:

   my $subtype_of_Num = Types::Standard::Num->create_child_type;
   my $subtype_of_Int = Types::Standard::Int->create_child_type;
   $subtype_of_Int->is_subtype_of( $subtype_of_Num );  # true

=item C<< strictly_equals($other) >>, C<< is_strictly_subtype_of($other) >>, C<< is_strictly_supertype_of($other) >>, C<< is_strictly_a_type_of($other) >>

Stricter versions of the type comparison functions. These only care about
explicit inheritance via C<parent>.

   my $subtype_of_Num = Types::Standard::Num->create_child_type;
   my $subtype_of_Int = Types::Standard::Int->create_child_type;
   $subtype_of_Int->is_strictly_subtype_of( $subtype_of_Num );  # false

=item C<< check($value) >>

Returns true iff the value passes the type constraint.

=item C<< validate($value) >>

Returns the error message for the value; returns an explicit undef if the
value passes the type constraint.

=item C<< assert_valid($value) >>

Like C<< check($value) >> but dies if the value does not pass the type
constraint.

Yes, that's three very similar methods. Blame L<Moose::Meta::TypeConstraint>
whose API I'm attempting to emulate. :-)

=item C<< assert_return($value) >>

Like C<< assert_valid($value) >> but returns the value if it passes the type
constraint.

This seems a more useful behaviour than C<< assert_valid($value) >>. I would
have just changed C<< assert_valid($value) >> to do this, except that there
are edge cases where it could break Moose compatibility.

=item C<< get_message($value) >>

Returns the error message for the value; even if the value passes the type
constraint.

=item C<< coerce($value) >>

Attempt to coerce C<< $value >> to this type.

=item C<< assert_coerce($value) >>

Attempt to coerce C<< $value >> to this type. Throws an exception if this is
not possible.

=item C<< can_be_inlined >>

Returns boolean indicating if this type can be inlined.

=item C<< inline_check($varname) >>

Creates a type constraint check for a particular variable as a string of
Perl code. For example:

   print( Types::Standard::Num->inline_check('$foo') );

prints the following output:

   (!ref($foo) && Scalar::Util::looks_like_number($foo))

For Moose-compat, there is an alias C<< _inline_check >> for this method.

=item C<< inline_assert($varname) >>

Much like C<inline_check> but outputs a statement of the form:

   die ... unless ...;

Note that if this type has a custom error message, the inlined code will
I<ignore> this custom message!!

=item C<< parameterize(@parameters) >>

Creates a new parameterized type; throws an exception if called on a
non-parameterizable type.

=item C<< create_child_type(%attributes) >>

Construct a new Type::Tiny object with this object as its parent.

=item C<< child_type_class >>

The class that create_child_type will construct.

=item C<< plus_coercions($type1, $code1, ...) >>

Shorthand for creating a new child type constraint with the same coercions
as this one, but then adding some extra coercions (at a higher priority than
the existing ones).

=item C<< plus_fallback_coercions($type1, $code1, ...) >>

Like C<plus_coercions>, but added at a lower priority.

=item C<< minus_coercions($type1, ...) >>

Shorthand for creating a new child type constraint with fewer type coercions.

=item C<< no_coercions >>

Shorthand for creating a new child type constraint with no coercions at all.

=item C<< isa($class) >>, C<< can($method) >>, C<< AUTOLOAD(@args) >>

If Moose is loaded, then the combination of these methods is used to mock
a Moose::Meta::TypeConstraint.

If Mouse is loaded, then C<isa> mocks Mouse::Meta::TypeConstraint.

=item C<< DOES($role) >>

Overridden to advertise support for various roles.

See also L<Type::API::Constraint>, etc.

=item C<< TIESCALAR >>, C<< TIEARRAY >>, C<< TIEHASH >>

These are provided as hooks that wrap L<Type::Tie>. (Type::Tie is distributed
separately, and can be used with non-Type::Tiny type constraints too.) They
allow the following to work:

   use Types::Standard qw(Int);
   tie my @list, Int;
   push @list, 123, 456;   # ok
   push @list, "Hello";    # dies

=back

The following methods exist for Moose/Mouse compatibility, but do not do
anything useful.

=over

=item C<< compile_type_constraint >>

=item C<< hand_optimized_type_constraint >>

=item C<< has_hand_optimized_type_constraint >>

=item C<< inline_environment >>

=item C<< meta >>

=item C<< type_parameter >>

=back

=head2 Overloading

=over

=item *

Stringification is overloaded to return the qualified name.

=item *

Boolification is overloaded to always return true.

=item *

Coderefification is overloaded to call C<assert_return>.

=item *

On Perl 5.10.1 and above, smart match is overloaded to call C<check>.

=item *

The C<< == >> operator is overloaded to call C<equals>.

=item *

The C<< < >> and C<< > >> operators are overloaded to call C<is_subtype_of>
and C<is_supertype_of>.

=item *

The C<< ~ >> operator is overloaded to call C<complementary_type>.

=item *

The C<< | >> operator is overloaded to build a union of two type constraints.
See L<Type::Tiny::Union>.

=item *

The C<< & >> operator is overloaded to build the intersection of two type
constraints. See L<Type::Tiny::Intersection>.

=item *

The C<< + >> operator is overloaded to call C<plus_coercions> or
C<plus_fallback_coercions> as appropriate.

=back

=head2 Constants

=over

=item C<< Type::Tiny::SUPPORT_SMARTMATCH >>

Indicates whether the smart match overload is supported on your
version of Perl.

=back

=head1 BUGS

Please report any bugs to
L<http://rt.cpan.org/Dist/Display.html?Queue=Type-Tiny>.

=head1 SEE ALSO

L<Type::Tiny::Manual>, L<Type::API>.

L<Type::Library>, L<Type::Utils>, L<Types::Standard>, L<Type::Coercion>.

L<Type::Tiny::Class>, L<Type::Tiny::Role>, L<Type::Tiny::Duck>,
L<Type::Tiny::Enum>, L<Type::Tiny::Union>, L<Type::Tiny::Intersection>.

L<Moose::Meta::TypeConstraint>,
L<Mouse::Meta::TypeConstraint>.

L<Type::Params>.

=head1 AUTHOR

Toby Inkster E<lt>tobyink@cpan.orgE<gt>.

=head1 THANKS

Thanks to Matt S Trout for advice on L<Moo> integration.

=head1 COPYRIGHT AND LICENCE

This software is copyright (c) 2013 by Toby Inkster.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=head1 DISCLAIMER OF WARRANTIES

THIS PACKAGE IS PROVIDED "AS IS" AND WITHOUT ANY EXPRESS OR IMPLIED
WARRANTIES, INCLUDING, WITHOUT LIMITATION, THE IMPLIED WARRANTIES OF
MERCHANTIBILITY AND FITNESS FOR A PARTICULAR PURPOSE.

