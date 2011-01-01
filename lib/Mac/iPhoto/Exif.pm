# ============================================================================
package Mac::iPhoto::Exif;
# ============================================================================

use 5.010;
use utf8;

use Moose;
with qw(MooseX::Getopt);

use Scalar::Util qw(weaken);
use MooseX::Types::Path::Class;
use XML::LibXML;
use Term::ANSIColor;
use File::Copy;
use DateTime;

use Image::ExifTool;
use Image::ExifTool::Location;

our $VERSION = version->new("1.00");

our $DATE_SEPARATOR = '[.:\/]';
our @LEVELS = qw(debug info warn error);
our $TIMERINTERVAL_EPOCH = 978307200; # Epoch of TimeInterval zero point: 2001.01.01
our $IPHOTO_ALBUM = $ENV{HOME}.'/Pictures/iPhoto Library/AlbumData.xml';

has 'iphoto_album'  => (
    is                  => 'ro',
    isa                 => 'Path::Class::File',
    coerce              => 1,
    default             => $IPHOTO_ALBUM,
    documentation       => "Path to iPhoto library [Default: $IPHOTO_ALBUM]",
);

has 'loglevel' => (
    is                  => 'ro',
    isa                 => Moose::Util::TypeConstraints::enum(\@LEVELS),
    default             => 'info',
);

has 'changetime'  => (
    is                  => 'ro',
    isa                 => 'Bool',
    documentation       => 'Change file time according to exif timestamps [Default: true]',
    default             => 1,
);

has 'backup'  => (
    is                  => 'ro',
    isa                 => 'Bool',
    documentation       => 'Backup files [Default: false]',
    default             => 0,
);

sub message {
    my ($self,@message) = @_;
    
    my $level_name = shift(@message)
        if $message[0] ~~ \@LEVELS;
    
    my $format = shift(@message) // '';
    my $logmessage = sprintf( $format, map { $_ // '000000' } @message );
    
    my ($level_pos) = grep { $LEVELS[$_] eq $level_name } 0 .. $#LEVELS;
    my ($level_max) = grep { $LEVELS[$_] eq $self->loglevel } 0 .. $#LEVELS;
    
    if ($level_pos >= $level_max) {
        given ($level_name) {
            when ('error') {
                print color 'bold red';
                printf "%5s: ",$level_name;
            }
            when ('warn') {
                print color 'bold bright_yellow';
                printf "%5s: ",$level_name;
            }
            when ('info') {
                print color 'bold cyan';
                printf "%5s: ",$level_name;
            }
            when ('debug') {
                print color 'bold white';
                printf "%5s: ",$level_name;
            }
        }
        print color 'reset';
        say $logmessage;
    }
}

sub run {
    my ($self) = @_;
    
    my $self_copy = $self;
    weaken($self_copy);
    local $SIG{__WARN__} = sub {
        my ($message) = shift;
        chomp $message;
        $self_copy->message('warn',$message);
    };
    
    binmode STDOUT, ":utf8";
    my $parser = XML::LibXML->new(
        encoding    => 'utf-8',
        no_blanks   => 1,
    );
    my $doc = eval {
        $self->message('info','Reading iPhoto album %s',$self->iphoto_album);
        return $parser->parse_file($self->iphoto_album);
    };
    if (! $doc) {
        $self->message('error','Could not parse iPhoto album: %s',$@ // 'unknown error');
        exit();
    }
    
    my $persons = {};
    my $keywords = {};
    my $count = 0;
    foreach my $top_node ($doc->findnodes('/plist/dict/key')) {
        given ($top_node->textContent) {
            when ('List of Faces') {
                my $personlist_node = $top_node->nextNonBlankSibling();
                my $persons_hash = _plist_node_to_hash($personlist_node);
                foreach my $person (values %$persons_hash) {
                    $persons->{$person->{key}} = $person->{name};
                }
                $self->message('info','Fetching faces (%i)',scalar(keys %$persons));
            }
            when ('List of Keywords') {
                my $keywordlist_node = $top_node->nextNonBlankSibling();
                $keywords = _plist_node_to_hash($keywordlist_node);
                $self->message('info','Fetching keywords (%i)',scalar(keys %$keywords));
            }
            when ('Master Image List') {
                my $imagelist_node = $top_node->nextNonBlankSibling();
                my $key;
                foreach my $image_node ($imagelist_node->childNodes) {
                    given ($image_node->nodeName) {
                        when ('key') {
                            $key = $image_node->textContent;
                        }
                        when ('dict') {
                            
                            my $image = _plist_node_to_value($image_node);
                            
                            my $image_path = Path::Class::File->new($image->{OriginalPath} || $image->{ImagePath});
                            my $latitude = $image->{latitude};
                            my $longitude = $image->{longitude};
                            my $rating = $image->{Rating};
                            my $comment = $image->{Comment};
                            my $faces = $image->{Faces};
                            
                            $self->message('info','Processing %s',$image_path->stringify);
                            my $exif = new Image::ExifTool(
                                Charset => 'UTF8',
                                #DateFormat=>undef
                            );
                            $exif->Options(DateFormat => undef);
                            
                            $exif->ExtractInfo($image_path->stringify);
                            
                            my $info = $exif->ImageInfo($image_path->stringify);
                            
                            my $date;
                            
                            # Take crazy date form iphoto album?
                            #my $date = $image->{DateAsTimerInterval} + $TIMERINTERVAL_EPOCH;
                            
                            if ($exif->GetValue('DateTimeOriginal') =~ m/^
                                (?<year>(19|20)\d{2})
                                $DATE_SEPARATOR
                                (?<month>\d{1,2})
                                $DATE_SEPARATOR
                                (?<day>\d{1,2})
                                \s
                                (?<hour>\d{1,2})
                                $DATE_SEPARATOR
                                (?<minute>\d{1,2})
                                $DATE_SEPARATOR
                                (?<second>\d{1,2})
                                /x) {
                                $date = DateTime->new(
                                    (map { $_ => $+{$_} } qw(year month day hour minute second)),
                                    time_zone   => 'floating',
                                );
                            } else {
                                $self->message('error','Could not parse date format %s',$exif->GetValue('DateTimeOriginal'));
                                next;
                            }
                            
                            my %keywords = map { $keywords->{$_} => 1 } @{$image->{Keywords}};
                            
                            my $changed_exif;
                            
                            # Faces
                            if (defined $faces && scalar @{$faces}) {
                                my $persons_changed = 0;
                                my @persons_list = $exif->GetValue('PersonInImage');
                                
                                foreach my $face (@$faces) {
                                    my $person = $persons->{$face->{'face key'}};
                                    next
                                        unless defined $person;
                                    next
                                        if $person ~~ \@persons_list;
                                    $self->message('debug','- Add person %s',$person);
                                    push(@persons_list,$person);
                                    $persons_changed = 1;
                                }
                                if ($persons_changed
                                    && scalar @persons_list) {
                                    $changed_exif = 1;
                                    $exif->SetNewValue('PersonInImage',[ sort @persons_list ]);
                                }
                            } 
                            
                            # Keywords
                            if (scalar keys %keywords) {
                                my $keywords_changed = 0;
                                my @keywords_list = $exif->GetValue('Keywords');
                                foreach my $keyword (keys %keywords) {
                                    next
                                        if $keyword ~~ \@keywords_list;
                                    $self->message('debug','- Add keyword %s',$keyword);
                                    push(@keywords_list,$keyword);
                                    $keywords_changed = 1;
                                }
                                if ($keywords_changed) {
                                    $changed_exif = 1;
                                    $exif->SetNewValue('Keywords',[ sort @keywords_list ]);
                                }
                            }
                            
                            # User comments
                            if ($comment) {
                                my $old_comment = $exif->GetValue('UserComment');
                                if ($old_comment ne $comment) {
                                    $self->message('debug','- Set user comment');
                                    $exif->SetNewValue('UserComment',$comment);
                                    $changed_exif = 1;
                                }
                            }
                            
                            # User ratings
                            if ($rating && $rating > 0) {
                                my $old_rating = $exif->GetValue('Rating') // 0;
                                if ($old_rating != $rating) {
                                    $self->message('debug','- Set rating %i',$rating);
                                    $exif->SetNewValue('Rating',$rating);
                                    $changed_exif = 1;
                                }
                            }
                            
                            # Geo Tags
                            if ($latitude && $longitude) {
                                my ($old_latitude,$old_longitude) = $exif->GetLocation($latitude,$longitude);
                                $old_latitude //= 0;
                                $old_longitude //= 0;
                                if (sprintf('%.4f',$latitude) != sprintf('%.4f',$old_latitude) 
                                    && sprintf('%.4f',$longitude) != sprintf('%.4f',$old_longitude)) {
                                    $self->message('debug','- Set geo location %fN,%fS',$latitude,$longitude);
                                    $exif->SetLocation($latitude,$longitude);
                                    $changed_exif = 1;
                                }
                            }
                            $changed_exif = 1;
                            if ($changed_exif) {
                                if ($self->backup) {
                                    my $backup_path = Path::Class::File->new($image_path->dir,'_'.$image_path->basename);
                                    $self->message('debug','- Writing backup file to %s',$backup_path->stringify);
                                    File::Copy::syscopy($image_path->stringify,$backup_path->stringify)
                                        or $self->message('error','Could not copy %s to %s: %s',$image_path->stringify,$backup_path->stringify,$!);
                                }
                                my $success = $exif->WriteInfo($image_path);
                                if ($success) {
                                    $self->message('debug','- Exif data has been written to %s',$image_path->stringify);
                                } else {
                                    $self->message('error','Could not write to %s: %s',$image_path->stringify,$exif->GetValue('Error'));
                                }
                            }
                            if ($self->changetime) {
                                $self->message('debug','- Change file time to %s',$date->datetime);
                                utime($date->epoch, $date->epoch, $image_path->stringify)
                                    or $self->message('error','Could not utime %s: %s',$image_path->stringify,$!);
                            }
                            
                            $count ++;
                        }
                    }
                }
            }
        }
    }
}

sub _plist_node_to_hash {
    my ($node) = @_;
    
    my $return = {};
    my $key;
    foreach my $child_node ($node->childNodes) {
        if ($child_node->nodeType == 1) {
            given ($child_node->nodeName) {
                when ('key') {
                    $key = $child_node->textContent;
                }
                default {
                    $return->{$key} = _plist_node_to_value($child_node);
                }
            }
        }
    }
    
    return $return;
}

sub _plist_node_to_value {
    my ($node) = @_;
    given ($node->nodeName) {
        when ('string') {
            return $node->textContent;
        }
        when ([qw(real integer)]) {
            return $node->textContent + 0;
        }
        when ('array') {
            return _plist_node_to_array($node);
        }
        when ('dict') {
            return _plist_node_to_hash($node);
        }
    }
}

sub _plist_node_to_array {
    my ($node) = @_;
    
    my $return = [];
    foreach my $child_node ($node->childNodes) {
        if ($child_node->nodeType == 1) {
            push (@$return,_plist_node_to_value($child_node));
        }
    }
    
    return $return;
}

1;
