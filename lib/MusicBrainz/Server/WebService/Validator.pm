package MusicBrainz::Server::WebService::Validator;
use MooseX::Role::Parameterized;
use aliased 'MusicBrainz::Server::WebService::WebServiceInc';
use aliased 'MusicBrainz::Server::WebService::WebServiceIncV1';
use MusicBrainz::Server::Constants qw(
    $ACCESS_SCOPE_TAG
    $ACCESS_SCOPE_RATING
    entities_with
);
use Class::MOP;
use Readonly;

parameter default_serialization_type => (
    is => 'ro',
    isa => 'Str',
    default => 'xml',
);

parameter version => (
    is => 'ro',
    isa => 'Str',
    default => '2',
);

parameter defs => (
    isa => 'ArrayRef',
);

our (%types, %statuses);
our %relation_types = (
    1 => {
        "area-rels" => 1,
        "artist-rels" => 1,
        "release-rels" => 1,
        "track-rels" => 1,
        "label-rels" => 1,
        "work-rels" => 1,
        "url-rels" => 1,
    },
    2 => { entities_with(['mbid', 'relatable'],
        take => sub {
            my (undef, $info) = @_;
            return ($info->{url} . '-rels' => 1)
        })
    }
);



# extra inc contains inc= arguments which should be allowed if another
# argument is present.  E.g. puids and isrcs only make sense on a
# request for a recording or a request with inc=recordings.  This hash
# helps validate the second case (inc=recordings).
our %extra_inc = (
    'recordings' => [ qw( artist-credits puids isrcs ) ],
    'releases' => [ qw( artist-credits discids media type status ) ],
    'release-groups' => [ qw( artist-credits type ) ],
    'works' => [ qw( artist-credits ) ],
);

# inc subqueries that limited to a maximum of 25 items. These are only
# supported for single-entity lookups, i.e. not browse requests or lookups
# that specify multiple IDs.
our %limited_subqueries = (
    artist          => { map { $_ => 1 } qw( recordings releases release-groups works ) },
    label           => { map { $_ => 1 } qw( releases ) },
    recording       => { map { $_ => 1 } qw( releases ) },
    release         => { map { $_ => 1 } qw( collections ) },
    'release-group' => { map { $_ => 1 } qw( releases ) },
);

sub load_type_and_status
{
    my ($c) = @_;

    %types = map {
        my ($name, $id) = @$_;
        (
            lc($name) => $id,
            lc("sa-$name") => $id,
            lc("va-$name") => $id
        )
    } (
        (map +[ lc($_->name) => $_->id ], $c->model('ReleaseGroupType')->get_all()),
        (map +[ lc($_->name) => 'st:' . $_->id ], $c->model('ReleaseGroupSecondaryType')->get_all())
    );

    my @statuses = $c->model('ReleaseStatus')->get_all();
    %statuses = map {
        lc($_->name) => $_->id,
        lc('sa-' . $_->name)=> $_->id,
        lc('va-' . $_->name)=> $_->id,
    } @statuses;

    $types{'nat'} = $types{'non-album tracks'};
}

sub validate_type
{
    my ($c, $resource, $type, $inc) = @_;

    return unless $type;

    load_type_and_status($c) if (!%types);

    unless ($inc->releases || $inc->release_groups ||
            $resource eq 'release' || $resource eq 'release-group')
    {
        $c->stash->{error} = "type is not a valid parameter unless releases or release-groups are requested.";
        $c->detach('bad_req');
    }

    my @type = split(/\|/, $type || '');

    my @ret;
    for (@type)
    {
        next unless $_;

        if (exists $types{$_})
        {
            push @ret, $types{$_};
        }
        else
        {
            $c->stash->{error} = "$_ is not a recognized release-group type.";
            $c->detach('bad_req');
        }
    }

    return \@ret;
}

sub validate_status
{
    my ($c, $resource, $status, $inc) = @_;

    return unless $status;

    load_type_and_status($c) if (!%statuses);

    unless ($inc->releases || $resource eq 'release')
    {
        $c->stash->{error} = "status is not a valid parameter unless releases are requested.";
        $c->detach('bad_req');
    }

    my @status = split(/\|/, $status || '');

    my @ret;
    for (@status)
    {
        next unless $_;

        if (exists $statuses{$_})
        {
            push @ret, $statuses{$_};
        }
        else
        {
            $c->stash->{error} = "$_ is not a recognized release status.";
            $c->detach('bad_req');
        }
    }

    return \@ret;
}

sub validate_linked
{
    my ($c, $resource, $def) = @_;

    my $params = $c->req->params;
    my %acc = map { $_ => 1 } @{ $def };

    my $linked;
    foreach (keys %$params)
    {
        return [$_, $params->{$_}] if (exists $acc{$_});
    }

    return undef;
}

sub validate_required
{
    my ($c, $required) = @_;

    foreach (@$required)
    {
        return 0 if (!exists $c->req->params->{$_} || $c->req->params->{$_} eq '');

        $c->stash->{args}->{$_} = $c->req->params->{$_};
    }

    return 1;
}

sub validate_inc
{
    my ($c, $version, $resource, $basename, $inc, $def) = @_;

    if (ref($inc)) {
        $c->stash->{error} = 'Inc arguments must be combined with a space, but you provided multiple parameters';
        return;
    }

    my @inc = split(/[+ ]/, $inc || '');
    my %acc = map { $_ => 1 } @{ $def };

    my $allow_type = exists $acc{"_rg_type"};
    my $allow_status = exists $acc{"_rel_status"};
    my $allow_relations = exists $acc{"_relations"};
    my $various_artists = 0;
    my $type_used = 0;
    my $status_used = 0;

    my @relations_used;
    my @filtered;

    my %extra;
    for my $i (@inc)
    {
        map { $extra{$_} = 1 } @{ $extra_inc{$i} } if (defined $extra_inc{$i});
    }

    for my $i (@inc)
    {
        next if (!$i);

        $i =~ s/mediums/media/;

        if ($version eq '1')
        {
            $i = lc($i);

            load_type_and_status($c) unless %types;

            if ($allow_type && exists $types{$i})
            {
                if ($type_used)
                {
                    $c->stash->{error} = "Only one type filter (e.g. $i) may be used per request.";
                    return;
                }
                $type_used = $types{$i};
                $various_artists = substr($i, 0, 3) eq 'va-' ? 1 : 0;
                next;
            }
            if ($allow_status && exists $statuses{$i})
            {
                if ($status_used)
                {
                    $c->stash->{error} = "Only one status filter (e.g. $i) may be used per request.";
                    return;
                }
                $status_used = $statuses{$i};
                $various_artists = substr($i, 0, 3) eq 'va-' ? 1 : 0;
                next;
            }
        }

        if ($allow_relations && exists $relation_types{$version}{$i})
        {
            push @relations_used, $i;
            next;
        }
        if (!exists $acc{$i} && !exists $extra{$i})
        {
            my @possible = grep {
                my %all = map { $_ => 1 } @{ $extra_inc{$_} };
                exists $all{$i}
            } keys %extra_inc;

            if (@possible) {
                $c->stash->{error} =
                    "$i is not a valid option for the inc parameter for the $resource resource " .
                    "unless you specify one of the following other inc parameters: " .
                        join(', ', @possible);
            }
            else {
                $c->stash->{error} = "$i is not a valid inc parameter for the $resource resource.";
            }

            return;
        }
        if (exists $limited_subqueries{$resource}{$i} &&
                defined $basename && $basename =~ /\+/) {
            $c->stash->{error} = "$i is not an allowed inc parameter when " .
                'multiple IDs are requested.';
            return;
        }
        push @filtered, $i;
    }

    if ($version eq '1')
    {
        return WebServiceIncV1->new(inc => \@filtered, rg_type => $type_used,
                                    rel_status => $status_used, relations => \@relations_used,
                                    various_artists => $various_artists);
    }
    else
    {
        return WebServiceInc->new(inc => \@filtered, rg_type => $type_used,
                                  rel_status => $status_used, relations => \@relations_used);
    }
}

role {
    my $r = shift;

    method 'validate' => sub
    {
        my ($self, $c) = @_;

        $c->stash->{serializer} = $self->get_serialization($c);

        my $version = quotemeta($r->version);
        my ($resource, $basename) = $c->req->path =~
            qr{ws/$version/([\w-]+?)(?:/(.*))?$};

        foreach my $def (@{ $r->defs })
        {
            # Match the call type
            next if ($resource ne $def->[0]);
            next if ($c->req->method ne $def->[1]->{method});

            # Check to make sure that required arguments are present
            next unless validate_required($c, $def->[1]->{required});

            my $linked;
            if ($def->[1]->{linked})
            {
                $linked = validate_linked($c, $resource, $def->[1]->{linked});
                next unless ($linked);
            }

            # include optional arguments
            foreach my $arg (@{ $def->[1]->{optional} })
            {
                if (exists $c->req->params->{$arg} && $c->req->params->{$arg} ne '')
                {
                    $c->stash->{args}->{$arg} = $c->req->params->{$arg};
                }
            }

            # MBS-9258: Map "Accept: application/json" to "fmt=json"
            $c->stash->{args}->{fmt} = $c->stash->{serializer}->fmt
                unless exists($c->stash->{args}->{fmt});

            # MBS-8994. Adding this here so we don't have to change every
            # 'optional' search attribute in every Controller::WS::2 class,
            # and it's an undocumented hack anyway, so this'll be easier to
            # remove later if needed.
            if (exists $c->stash->{args}{query} &&
                    exists $c->req->params->{dismax} &&
                    $c->req->params->{dismax} ne '') {
                $c->stash->{args}{dismax} = $c->req->params->{dismax};
            }

            # Check to make sure that only appropriate inc values have been requested
            my $inc = do {
                my $class = $version eq '2' ? WebServiceInc : WebServiceIncV1;
                $class->new;
            };

            if ($def->[1]->{inc})
            {
                $inc = validate_inc($c, $r->version, $resource, $basename,
                                    $c->req->params->{inc}, $def->[1]->{inc});
                return 0 unless ($inc);
            }

            if ($inc && $version eq '2') {
                $c->stash->{type} = validate_type($c, $resource, $c->req->params->{type}, $inc);
                $c->stash->{status} = validate_status($c, $resource, $c->req->params->{status}, $inc);
            }

            # Check if authorization is required.
            $c->stash->{authorization_required} = $inc->{user_tags} || $inc->{user_ratings} ||
                $resource eq 'tag' || $resource eq 'rating' ||
                ($resource eq 'release' && $c->req->method eq 'POST') ||
                ($resource eq 'recording' && $c->req->method eq 'POST');

            # Check authorization scope.
            my $scope = 0;
            $scope |= $ACCESS_SCOPE_TAG if $inc->{user_tags} || $resource eq 'tag';
            $scope |= $ACCESS_SCOPE_RATING if $inc->{user_ratings} || $resource eq 'rating';
            $c->stash->{authorization_scope} = $scope;

            # All is well! Set up the stash!
            $c->stash->{inc} = $inc;
            $c->stash->{linked} = $linked;
            return 1;
        }
        $c->stash->{error} = "The given parameters do not match any available query type for the $resource resource.";
        return 0;
    };
};

1;
