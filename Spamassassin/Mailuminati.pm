# Mailuminati Guardian 
# Copyright (C) 2025 Simon Bressier
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, version 3.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

package Mail::SpamAssassin::Plugin::Mailuminati;

use strict;
use warnings;
use Mail::SpamAssassin::Plugin;
use LWP::UserAgent;
use JSON;

use vars qw(@ISA);
@ISA = qw(Mail::SpamAssassin::Plugin);

sub new {
    my ($class, $mailsa) = @_;
    $class = ref($class) || $class;
    my $self = $class->SUPER::new($mailsa);
    bless ($self, $class);

    $self->register_eval_rule("check_mailuminati_spam");
    $self->register_eval_rule("check_mailuminati_suspicious");
    
    # Default configuration
    $self->{mailuminati_config} = {
        endpoint => 'http://127.0.0.1:12421/analyze',
        timeout  => 5,
    };

    return $self;
}

sub parse_config {
    my ($self, $opts) = @_;
    my $key = $opts->{key};
    
    if ($key eq 'mailuminati_endpoint') {
        $self->{mailuminati_config}->{endpoint} = $opts->{value};
        $self->inhibit_further_callbacks();
        return 1;
    }
    if ($key eq 'mailuminati_timeout') {
        $self->{mailuminati_config}->{timeout} = $opts->{value};
        $self->inhibit_further_callbacks();
        return 1;
    }
    return 0;
}

sub _run_scan {
    my ($self, $pms) = @_;
    
    # Return if already scanned for this message
    return if defined $pms->{mailuminati_result};
    
    # Initialize default result
    $pms->{mailuminati_result} = { spam => 0, susp => 0 };

    my $msg_content = $pms->{msg}->get_pristine();
    
    my $ua = LWP::UserAgent->new;
    $ua->timeout($self->{mailuminati_config}->{timeout});
    $ua->agent("Mailuminati-SA-Plugin/1.0");
    
    my $response = $ua->post(
        $self->{mailuminati_config}->{endpoint},
        Content => $msg_content,
        'Content-Type' => 'text/plain'
    );

    if ($response->is_success) {
        my $content = $response->decoded_content;
        my $json;
        
        eval { $json = decode_json($content); };
        if ($@) {
            warn "Mailuminati: JSON decode error: $@";
            return;
        }
        
        if (defined $json->{action} && ($json->{action} eq 'spam' || $json->{action} eq 'reject')) {
             $pms->{mailuminati_result}->{spam} = 1;
        }
        if (defined $json->{proximity_match} && $json->{proximity_match}) {
             $pms->{mailuminati_result}->{susp} = 1;
        }
    } else {
        # Only warn on debug or if it's a real error, not just connection refused if service is down
        dbg("Mailuminati: HTTP error: " . $response->status_line);
    }
}

sub check_mailuminati_spam {
    my ($self, $pms) = @_;
    $self->_run_scan($pms);
    return $pms->{mailuminati_result}->{spam};
}

sub check_mailuminati_suspicious {
    my ($self, $pms) = @_;
    $self->_run_scan($pms);
    return $pms->{mailuminati_result}->{susp};
}

1;
