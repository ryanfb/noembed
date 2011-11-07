package Noembed::Source::Twitter;

use JSON;
use AnyEvent;
use AnyEvent::HTTP;
use Text::MicroTemplate qw/encoded_string/;

use parent 'Noembed::Source';

sub prepare_source {
  my $self = shift;
  $self->{url_re} = qr{(http://t\.co/[0-9a-zA-Z]+)};
  $self->{name_re} = qr{(?:^|\W)(@[^\s:]+)};
}

sub patterns { 'https?://(?:www\.)?twitter\.com/(?:#!/)?[^/]+/status(?:es)?/(\d+)' }
sub provider_name { "Twitter" }

sub request_url {
  my ($self, $req) = @_;
  my $id = $req->captures->[0];
  return "http://api.twitter.com/1/statuses/show/$id.json";
}

sub post_download {
  my ($self, $body, $cb) = @_;
  my $tweet = from_json $body;
  $self->download_parents($tweet, sub {
    $self->expand_links($tweet, sub {$cb->($tweet)});
  });
}

sub download_parents {
  my ($self, $tweet, $cb) = @_;
  my $parent_id = $tweet->{in_reply_to_status_id};
  return $cb->() unless $parent_id;

  http_request get => "http://api.twitter.com/1/statuses/show/$parent_id.json", {
        persistent => 0,
        keepalive  => 0,
    },
    sub {
      my ($body, $headers) = @_;
      return $cb->() unless $headers->{Status} == 200;;

      my $parent = decode_json $body;
      $tweet->{parent_tweet} = $parent;
      $self->expand_links($parent, sub {$self->download_parents($parent, $cb)});
    };
}

sub expand_links {
  my ($self, $tweet, $cb) = @_;

  my $done = sub {
    $tweet->{$_} = encoded_string $tweet->{$_} for qw/source text/;
    $cb->()
  };

  my @names = $tweet->{text} =~ /$self->{name_re}/g;
  for my $name (@names) {
    $tweet->{text} =~ s{\Q$name\E}{<a target="_blank" href="http://twitter.com/$name">$name</a>};
  }

  my @urls = $tweet->{text} =~ /$self->{url_re}/g; 
  return $done->() unless @urls;

  my $cv = AE::cv;

  for my $url (@urls) {
    $cv->begin;
    Noembed::http_resolve $url, sub {
      my $resolved = shift;
      $tweet->{text} =~ s/\Q$url\E/$resolved/;
      $cv->end;
    };
  }

  $cv->cb($done);
}

sub serialize {
  my ($self, $tweet) = @_;

  return +{
    title => "Tweet by $tweet->{user}{name}",
    html  => $self->render($tweet),
  };
}

1;
