# -*- perl -*-

# t/01_basic.t - basic tests

use Test::Most tests => 2+1;
use Test::NoWarnings;

use Mac::iPhoto::Exif;

my $iphoto_exif = Mac::iPhoto::Exif->new(
    iphoto_album    => 't/AlbumData.xml',
    backup          => 1,
);

$iphoto_exif->run;

ok(-e 't/_IMG_01.JPG','Backup has been created');


# Clean up after test
unlink('t/IMG_01.JPG');
unlink('t/IMG_02.JPG');
rename('t/_IMG_01.JPG','t/IMG_01.JPG');
rename('t/_IMG_02.JPG','t/IMG_02.JPG');

isa_ok($iphoto_exif,'Mac::iPhoto::Exif');

