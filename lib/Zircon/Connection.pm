
package Zircon::Connection;

use strict;
use warnings;
use feature qw( switch );

use Carp;
use Scalar::Util qw( weaken );
use Try::Tiny;

use base qw( Zircon::Trace );
our $ZIRCON_TRACE_KEY = 'ZIRCON_CONNECTION_TRACE';

my @mandatory_args = qw(
    name
    context
    handler
    );

my $optional_args = {
    'timeout_interval' => 500, # 0.5 seconds
    'timeout_retries_initial' => 10,
    'connection_id'    => __PACKAGE__,
    'local_endpoint' => undef,
};

my @weak_args = qw(
    handler
    );

sub new {
    my ($pkg, %args) = @_;
    my $new = { };
    bless $new, $pkg;
    $new->init(\%args);
    return $new;
}

sub init {
    my ($self, $args) = @_;

    for my $key (@mandatory_args) {
        my $value = $args->{"-${key}"};
        defined $value or die "missing -${key} parameter";
        $self->{$key} = $value;
    }

    while (my ($key, $default) = each %{$optional_args}) {
        my $value = $args->{"-${key}"};
        defined $value or $value = $default;
        $self->$key($value) if defined $value;
    }

    for my $key (@weak_args) {
        weaken $self->{$key};
    }

    $self->{my_request_id} //= 0;

    $self->trace_env_update;

    $self->context->set_connection_params(
        timeout_interval        => $self->timeout_interval,
        timeout_retries_initial => $self->timeout_retries_initial,
        );

    # deferred to here in case we're setting local_endpoint
    $self->context->transport_init(
        sub {
            return $self->_server_callback(@_);
        },
        sub {
            return $self->_fire_after;
        },
        );

    $self->state('inactive');   # state now redundant?

    $self->zircon_trace('Initialised');

    return;
}

# client

sub send {
    my ($self, $request, $request_id) = @_;

    if ($request_id) {
        $request_id >= $self->my_request_id
            or die sprintf('request_id [%d] out of sync, exp [%d]', $request_id, $self->my_request_id);
        $self->my_request_id($request_id);
    } else {
        $request_id = $self->my_request_id;
    }

    $self->zircon_trace("start");

    my $reply;
    my ($rv, $collision) = $self->context->send($request, \$reply, $request_id);

    my $collision_result = 'clear';
    if ($collision) {
        if (ref($collision) eq 'CODE') {
            $collision_result = 'WIN';
        } else {
            $self->zircon_trace('collision lost');
            $collision_result = 'LOSE';
        }
    }
    if ($rv >= 0) {
        $self->zircon_trace("client got reply '%s'", $reply);
        $self->handler->zircon_connection_reply($reply, $collision_result);
        $self->my_request_id(++$request_id);
    } else {
        $self->zircon_trace('client timed out after retrying');
        $self->timeout_maybe_callback;
    }
    if ($collision_result eq 'WIN') {
        $self->zircon_trace('post-collision callback');
        $collision->();
    }

    $self->_fire_after;
    $self->zircon_trace("finish");

    return;
}

sub _fire_after {
    my ($self) = @_;
    if (my $after = $self->after) {
        $self->zircon_trace;
        $self->after->();
        $self->after(undef);
    }
    return;
}

# server

sub _server_callback {
    my ($self, $request, $header, $collision_result) = @_;

    my $request_id = $header->{request_id};
    my $attempt    = $header->{request_attempt};

    $self->zircon_trace('start (req %d/%d, collision: %s)', $request_id, $attempt, $collision_result // 'none');
    $self->zircon_trace("request: '%s'", $request);

    my $reply;

    my $rrid = $self->remote_request_id;
    if ($attempt > 1 and $rrid and $rrid == $request_id and $self->last_reply) {
        # Retransmit
        $self->zircon_trace('retransmit');
        $reply = $self->last_reply;
    } else {
        # Not seen this request before
        warn "Out of sequence: last ${rrid}, this ${request_id}" if ($rrid and $request_id <= $rrid);
        $reply = $self->handler->zircon_connection_request($request, $collision_result);
        $self->remote_request_id($request_id);
        $self->last_reply($reply);
    }

    $self->zircon_trace('finish');

    return $reply;
}

# endpoints

sub local_endpoint {
    my ($self, @args) = @_;
    warn "setting local_endpoint to '", $args[0], "'" if @args;
    return $self->context->local_endpoint(@args)
}

sub remote_endpoint {
    my ($self, @args) = @_;
    $self->zircon_trace("setting remote_endpoint to '%s'", $args[0]) if @args;
    return $self->context->remote_endpoint(@args);
}

# timeouts

sub timeout_start {
    my ($self, $retries) = @_;
    $retries = $self->timeout_retries_initial unless defined $retries;
    my $timeout_handle =
        $self->timeout(
            $self->timeout_interval,
            $self->callback('timeout_maybe_callback'));
    $self->timeout_retries($retries);
    $self->timeout_handle($timeout_handle);
    return;
}

sub timeout_cancel {
    my ($self) = @_;
    my $timeout_handle = $self->timeout_handle;
    if (defined $timeout_handle) {
        $timeout_handle->cancel;
        $self->timeout_handle(undef);
    }
    return;
}

# Time is up, but maybe we will wait again
sub timeout_maybe_callback {
    my ($self) = @_;
    if (my $retries = $self->timeout_retries) {
        $self->zircon_trace('retry [%d]', $retries);
        $self->timeout_start($retries - 1);
    } else {
        # we've waited long enough
        $self->timeout_callback;
    }
    return;
}

sub timeout_callback {
    my ($self) = @_;
    $self->timeout_handle(undef);
    $self->after(undef);
    $self->zircon_trace;
    try { $self->handler->zircon_connection_timeout; }
    catch { die $_; } # propagate any error
    finally { $self->reset; };
    return;
}

sub timeout_interval {
    my ($self, @args) = @_;
    ($self->{'timeout_interval'}) = @args if @args;
    return $self->{'timeout_interval'};
}

sub timeout_handle {
    my ($self, @args) = @_;
    ($self->{'timeout_handle'}) = @args if @args;
    return $self->{'timeout_handle'};
}

sub timeout_retries {
    my ($self, @args) = @_;
    ($self->{'timeout_retries'}) = @args if @args;
    return $self->{'timeout_retries'};
}

sub timeout_retries_initial {
    my ($self, @args) = @_;
    ($self->{'timeout_retries_initial'}) = @args if @args;
    return $self->{'timeout_retries_initial'};
}

sub timeout {
    my ($self, @args) = @_;
    my $timeout_handle =
        $self->context->timeout(@args);
    return $timeout_handle;
}

# callbacks

sub callback {
    my ($self, $method) = @_;
    return $self->{'callback'}{$method} ||=
        $self->_callback($method);
}

sub _callback {
    my ($self, $method) = @_;
    weaken $self; # break circular references
    my $callback = sub {
        defined $self or return; # because a weak reference may become undef
        return $self->$method(@_);
    };
    return $callback;
}

sub reset {
    my ($self) = @_;
    $self->zircon_trace;
    return;
}

# tracing

sub zircon_trace_prefix {
    my ($self) = @_;
    return sprintf "connection: %s: id = '%s'", $self->name, $self->connection_id;
}

# attributes

sub name {
    my ($self) = @_;
    my $name = $self->{'name'};
    return $name;
}

sub handler {
    my ($self) = @_;
    return $self->{'handler'};
}

sub context {
    my ($self) = @_;
    return $self->{'context'};
}

sub connection_id {
    my ($self, @args) = @_;
    ($self->{'connection_id'}) = @args if @args;
    return $self->{'connection_id'};
}

sub my_request_id {
    my ($self, @args) = @_;
    ($self->{'my_request_id'}) = @args if @args;
    my $my_request_id = $self->{'my_request_id'};
    return $my_request_id;
}

sub remote_request_id {
    my ($self, @args) = @_;
    ($self->{'remote_request_id'}) = @args if @args;
    my $remote_request_id = $self->{'remote_request_id'};
    return $remote_request_id;
}

sub last_reply {
    my ($self, @args) = @_;
    ($self->{'last_reply'}) = @args if @args;
    my $last_reply = $self->{'last_reply'};
    return $last_reply;
}

sub after {
    my ($self, @args) = @_;
    ($self->{'after'}) = @args if @args;
    return $self->{'after'};
}

sub state {
    my ($self, @args) = @_;
    ($self->{'state'}) = @args if @args;
    return $self->{'state'};
}

1;

=head1 NAME - Zircon::Connection

=head1 METHODS

=head2 C<new()>

Create a Zircon connection.

    my $connection = Zircon::Connection->new(
        -context => $context, # mandatory
        -handler => $handler, # mandatory
        -timeout_interval => $timeout, # optional, in millisec
        -timeout_retries_initial => $count, # optional
        );

=over 4

=item C<$context> (mandatory)

An opaque object that provides an interface to the transport layer
and the application's event loop.

Perl/Tk applications create this object by calling
C<Zircon::TkZMQ::Context-E<gt>new()>.

=item C<$handler> (mandatory)

An object that processes client requests, server replies and
connection timeouts.

NB: the caller must keep a reference to the handler.  This is because
the connection keeps only a weak reference to the handler to prevent
circular references, since the handler will generally keep a reference
to the connection.

=item C<$timeout> (optional)

The timeout interval in milliseconds.

If at any time the other end of the connection does not respond within
the timeout interval, then the connection calls the handler's timeout
method and then resets.

This value defaults to 500 if not supplied.

=item C<$count> (optional)

The number of times the timeout may be restarted, per phase.  This is
used when we have some reason to think the peer is still present:
remote window still exists, or we are waiting for the handshake to
complete.

=back

=head2 C<local_endpoint()>, C<remote_endpoint()>

Get/set endpoint addresses.

    my $id = $connection->local_endpoint;
    $connection->local_endpoint($id);
    my $id = $connection->remote_endpoint;
    $connection->remote_endpoint($id);

Setting the local endpoint makes the connection respond to
requests from clients using that address.

Setting the remote endpoint allows the connection to send requests
to a server using that address.

=head2 C<send()>

Send a request to the server.

    $connection->send($request);

This requires the remote endpoint to be set.

$request is a string.

=head2 C<after()>

Defer an action until after the client/server exchange completes
successfully.

    $connection->after(sub { ... });

The subroutine argument will be called once after the current
client/server exchange completes, provided that the connection did not
reset.

This method should only be called

=over 4

=item * during L<Zircon::Connection::Handler/zircon_connection_request>

To be notified when the client acknowledges your reply

=item * just before the L</send> method

To be notified after we acknowledge the remote server's reply.

=back

If it is called several times then only the last call has any effect.

=head2 C<$handler-E<gt>zircon_connection_request()>

    my $reply = $handler->zircon_connection_request($request);

Process a request from the client and return a reply to be sent to the
client.

This method can call C<$connection-E<gt>after()> to schedule code to
be run after the client acknowledges receiving the reply.

If this raises a Perl error then the connection resets.  The error is
propagated to the application's main loop.

This will only be called if the local endpoint is set.

$request and $reply are strings.

=head2 C<$handler-E<gt>zircon_connection_reply()>

    $handler->zircon_connection_reply($reply);

Process a reply from the server (when acting as a client).

If this raises a Perl error then the connection resets.  The error is
propagated to the application's main loop.

This will only be called if the local endpoint is set.

$reply is a string.

=head2 C<$handler-E<gt>zircon_connection_timeout()>

    $handler->zircon_connection_timeout();

Process a connection timeout.

=head1 SEQUENCE OF EVENTS

    - client : sets request
    - server : reads request
    - client :
    - server : sets reply
    - client : reads reply
    - server :
    - client : processes reply

=head1 AUTHOR

Ana Code B<email> anacode@sanger.ac.uk
