#!/usr/bin/perl
use strict;
use warnings;

use Getopt::Euclid qw(:defer);
use feature ':5.10';

use LWP::UserAgent;
use Digest::MD5 qw(md5);
use Math::Trig qw(asin);
use Time::HiRes 'usleep';

my @ARGV_original = @ARGV;
my @thiscmd_tokens = split('/',$0);
my $thiscmd =  $thiscmd_tokens[-1];
Getopt::Euclid->process_args(\@ARGV);

if( $ARGV{'--feedgnuplot'} && $ARGV{'--gnuplotlib'}) {
    die("--feedgnuplot and --gnuplotlib are mutually exclusive");
}

my $pi     = 3.14159265359;
my $Rearth = 6371000.0; # meters


my $center_lat = $ARGV{'--center'}{lat};
my $center_lon = $ARGV{'--center'}{lon};
my $zoom       = $ARGV{'--zoom'};

# I want radius in meters
my ($rad,$unit) = $ARGV{'--rad'} =~ /([0-9\.]+)(.*?)$/;
if   ($unit =~ /mile/) { $rad *= 5280 * 12 * 2.54 / 100; }
elsif($unit =~ /km/ )  { $rad *= 1000; }


my $url = $ARGV{'--serverpath'};
$url =~ s{/*$}{}g;        # remove any trailing /

my $url_alphanumeric = $url;
$url_alphanumeric =~ s{^[a-z]+://}{}i; # remove leading http://, https://, ftp:// and so on
$url_alphanumeric =~ s/[^0-9a-z_]/./gi;


# Get the lat/lon bounds I want
my @lat = ($center_lat - $rad/$Rearth * 180.0/$pi,
           $center_lat + $rad/$Rearth * 180.0/$pi );
my @lon = ($center_lon - $rad/$Rearth * 180.0/$pi / cos($center_lat * $pi/180.0),
           $center_lon + $rad/$Rearth * 180.0/$pi / cos($center_lat * $pi/180.0) );

my ($montage_filename, $width, $height,
    $lat_px_cropped, $lon_px_cropped,
    $lat_cropped, $lon_cropped) = make_montage(\@lat, \@lon, $zoom);



# Now I generate the gnuplot script. The auto-tic business doesn't appear to
# work right with the nonlinear axis mapping, so I do it myself. I find the
# nearest spacing that's either 1eX or 0.5eX
my $tic_spacing = ($lon_cropped->[1] - $lon_cropped->[0]) / 10;
sub split_sci_notation
{
    # takes in a * 10^x and returns a where x is an integer, a >=1 and a < 10
    sub fractional
    {
        my $x = shift;
        return $x - int($x);
    }

    my $x        = $_[0];
    my $mantissa = 10.0 ** fractional(log($x)/log(10) + 100);
    my $exp      = log($x / $mantissa)/log(10);
    return ($mantissa,$exp);
}
my ($mantissa,$exp) = split_sci_notation($tic_spacing);
if( $mantissa < 2.5 )
{
    $tic_spacing = 10**$exp;
}
elsif( $mantissa < 7.5 )
{
    $tic_spacing = 5 * 10**$exp;
}
else
{
    $tic_spacing = 10**($exp+1);
}



my $cmds = <<EOF;
attenuation = 1.5

set autoscale noextend

lat_offset_px = $lat_px_cropped->[0]
lon_offset_px = $lon_px_cropped->[0]

s1_cos(x)     = (sin(x)+1)/cos(x)
inv_s1_cos(x) = asin( (x**2 - 1)/(x**2 + 1) )

px_to_lon(x) = (x + lon_offset_px)/(256. * 2.**$zoom)*360. - 180.
lon_to_px(x) = (x+180.)/360. * 2.**$zoom * 256 - lon_offset_px

px_to_lat(x) = inv_s1_cos(exp((1 - (x + lat_offset_px)/(2.**$zoom * 256) *2)*pi))*180./pi
lat_to_px(x) = (1 - log( (sin(x*pi/180) + 1.)/cos(x*pi/180) )/pi)/2. * 2.**$zoom * 256 - lat_offset_px


set link x2 via px_to_lon(x) inverse lon_to_px(x)
set link y2 via px_to_lat(y) inverse lat_to_px(y)

unset xtics
unset ytics

set grid front
set x2tics mirror $tic_spacing
set y2tics mirror $tic_spacing

set size ratio -1

set x2label "Longitude (degrees)"
set y2label "Latitude (degrees)"

EOF


my $gnuplot_script = <<EOF;
# Generated by osmgnuplot.pl from
#   https://github.com/dkogan/osmgnuplot
#
# Command used:
#   $thiscmd @ARGV_original

$cmds

set xrange [0:$width-1]
set yrange [$height-1:0]

plot "$montage_filename" binary filetype=png flipy using (\$1/attenuation):(\$2/attenuation):(\$3/attenuation) with rgbimage notitle axis x1y1
EOF

my $feedgnuplot_script = <<EOF;
# Generated by osmgnuplot.pl from
#   https://github.com/dkogan/osmgnuplot
#
# Command used:
#   $thiscmd @ARGV_original

feedgnuplot \\
  --cmds '$cmds' \\
  --set 'xrange [0:$width-1]'  \\
  --set 'yrange [$height-1:0]' \\
  --equation '"$montage_filename" binary filetype=png flipy using (\$1/attenuation):(\$2/attenuation):(\$3/attenuation) with rgbimage notitle axis x1y1'
EOF

my $gnuplotlib_script = <<EOF;
#!/usr/bin/python3

# Generated by osmgnuplot.pl from
#   https://github.com/dkogan/osmgnuplot
#
# Command used:
#   $thiscmd @ARGV_original

import gnuplotlib as gp

cmds = r'''$cmds'''

# With gnuplotlib 0.43, gnuplot 6.0.0 I see the gnuplotlib test code result in
# the inverted y axis being ignored. For now I work-around this with
# "notest=True" here

# gnuplotlib 0.43 doesn't have facilities to request an axis other than x1y2,
# while here I need x2y2. Until that is fixed, I fake it with with "_with"
# keyword


# import numpy as np
# latlon = np.array(((34.0767,-118.284),
#                    (34.0705,-118.268),))

gp.plot( # latlon[:,1], latlon[:,0], _with = 'linespoints axes x2y2',
        cmds      = cmds,
        _xrange   = (0, $width-1),
        _yrange   = ($height-1, 0),
        equation  = '"$montage_filename" binary filetype=png flipy using (\$1/attenuation):(\$2/attenuation):(\$3/attenuation) with rgbimage notitle axis x1y1',
        notest    = True,
        wait      = True,
       )
EOF



if( $ARGV{'--feedgnuplot'})
{
    my $shfilename = $montage_filename;
    $shfilename =~ s/png$/sh/;

    open SH, '>', $shfilename;
    print SH $feedgnuplot_script;
    close SH;

    say "Done! Shell script '$shfilename' uses the image '$montage_filename'";
}
elsif( $ARGV{'--gnuplotlib'})
{
    my $pyfilename = $montage_filename;
    $pyfilename =~ s/png$/py/;

    open PY, '>', $pyfilename;
    print PY $gnuplotlib_script;
    close PY;

    say "Done! Python script '$pyfilename' uses the image '$montage_filename'";

}
else
{
    # default. gnuplot script
    my $gpfilename = $montage_filename;
    $gpfilename =~ s/png$/gp/;

    open GP, '>', $gpfilename;
    print GP $gnuplot_script;
    close GP;

    say "Done! Gnuplot script '$gpfilename' uses the image '$montage_filename'";
}












sub make_montage
{
    my ($lat, $lon, $zoom) = @_;

    # The requested lat/lon ranges are given. The image we output is granular to
    # pixels, so we can't hit these latlon coords exactly, but we get as close
    # as we can. We return the resulting lat/lon and pixel ranges

    # The global tile indices of the corners. This tells me which tiles need to
    # be downloaded. The tiles cover a larger area than what I care about
    my @tilex =         map { lon2tilex($_, $zoom ) } @$lon;
    my @tiley = reverse map { lat2tiley($_, $zoom ) } @$lat; # lat pixels map in
                                                             # opposite order.
                                                             # SMALL y pixel
                                                             # coords correspond
                                                             # to HIGH latitudes

    my $userAgent = LWP::UserAgent->new;
    $userAgent->agent("osmgnuplot.pl");

    my @montage_tile_list;
    for my $y ($tiley[0]..$tiley[1])
    {
        for my $x ($tilex[0]..$tilex[1])
        {
            my $path = tile2path($x, $y, $zoom);
            my $tileurl = "$url/$path";
            my $filename = "tile_${url_alphanumeric}__${x}_${y}_${zoom}.png";


            my @get_args = (":content_file" => $filename);

            if ( -r $filename )
            {
                # a local file exists. use it if possible

                # compute the checksum of the local file
                local  $/ = undef;
                open TILE, $filename;
                my $md5_cache = join('', unpack('H*', md5(<TILE>)));
                close TILE;

                # tells server to only send data if needed
                push @get_args, ('if-none-match' => "\"$md5_cache\"" );
            }
            else
            {
                say STDERR "Downloading $tileurl into '$filename'";
                $userAgent->get($tileurl, @get_args)
                  or die "Error downloading '$tileurl'";
                usleep(100_000);
            }

            push @montage_tile_list, $filename;
        }
    }

    # I downloaded all my tiles. I stitch the tiles into one large image, then
    # crop so that the corners sit at the lat/lon I want
    my $Ntiles_width  = $tilex[1] - $tilex[0] + 1;
    my $Ntiles_height = $tiley[1] - $tiley[0] + 1;

    # The LOCAL pixel coords of the corners inside my uncropped montage
    my @lon_px = map { int( 0.5 + lon2pixels($_, $zoom) - 256*$tilex[0] ) }         @lon;
    my @lat_px = map { int( 0.5 + lat2pixels($_, $zoom) - 256*$tiley[0] ) } reverse @lat;


    my $width  = $lon_px[1] - $lon_px[0] + 1;
    my $height = $lat_px[1] - $lat_px[0] + 1;


    my $montage_filename = "montage_${center_lat}_${center_lon}_$ARGV{'--rad'}_$zoom.png";
    system("montage @montage_tile_list -tile ${Ntiles_width}x${Ntiles_height} -geometry +0+0 - " .
           "| convert -crop ${width}x${height}+$lon_px[0]+$lat_px[0] - $montage_filename") == 0
      or die "Error running montage/crop: $@";


    # I cropped the image to some discrete pixel values, so I recompute the
    # lat/lon coords of the corners EXACTLY
    my @lon_px_cropped = ($tilex[0]*256 + $lon_px[0],
                          $tilex[0]*256 + $lon_px[0] + $width-1);
    my @lat_px_cropped = ($tiley[0]*256 + $lat_px[0],
                          $tiley[0]*256 + $lat_px[0] + $height-1);
    my @lon_cropped = ( pixels2lon($lon_px_cropped[0], $zoom),
                        pixels2lon($lon_px_cropped[1], $zoom) );
    my @lat_cropped = ( pixels2lat($lat_px_cropped[1], $zoom),
                        pixels2lat($lat_px_cropped[0], $zoom) );
    return ($montage_filename, $width, $height,
            \@lat_px_cropped, \@lon_px_cropped,
            \@lat_cropped, \@lon_cropped);
}

sub get_approximate_pixel_mapping
{
    my ($width, $height, $lat, $lon) = @_;

    # I now generate a gnuplot script. Here I require dx,dy,centerx,centery to
    # properly scale, position the montage. I have the width, height of the
    # image and the lat/lon positions of the corners. Note that the values
    # reported by this function assume that the relationship between pixel
    # coords and lat/lon is linear. This is true for lon but NOT for lat. Thus
    # the values returned here are not correct when looking at a large range of
    # lat

    # dx/dy is latlon/pixel
    my $dx = ($lon->[1] - $lon->[0]) / ($width  - 1);
    my $dy = ($lat->[1] - $lat->[0]) / ($height - 1);

    my $centerx = ($lon->[0] + $lon->[1]) / 2.0;
    my $centery = ($lat->[0] + $lat->[1]) / 2.0;

    return ($centerx, $centery, $dx, $dy);
}


# These come mostly from Geo::OSM::Tiles. I needed my own tile_from_lat()
# anyway, so I may as well copy these here to not require the dependency.
#
# These are Copyright (C) 2008-2010 by Rolf Krahl, distributed under the same
# terms as Perl itself, either Perl version 5.8.8 or, at your option, any later
# version of Perl 5 you may have available.
sub lon2pixels
{
    my ($lon, $zoom) = @_;
    return ($lon+180.)/360. * 2.**($zoom+8.);
}
sub lon2tilex
{
    return int(lon2pixels(@_) / 256);
}
sub pixels2lon
{
    my ($px, $zoom) = @_;
    return $px * 2.**(-$zoom-8.) * 360.0 - 180.0;
}
sub lat2pixels
{
    my ($lat, $zoom) = @_;
    my $lata = $lat*$pi/180.;

    my $s = sin($lata);
    my $c = cos($lata);
    return (1.0 - log( ($s + 1.)/$c )/$pi) * 2.**($zoom+7);
}
sub lat2tiley
{
    return int(lat2pixels(@_) / 256);
}
sub pixels2lat
{
    my ($px, $zoom) = @_;


    sub inv_s1_cos
    {
        my $x = shift;

        # inverse of (sin(x)+1)/cos(x)
        return asin( ($x**2. - 1)/($x**2. + 1.) );
    }

    return inv_s1_cos(exp((1.0 - $px * 2.**(-$zoom-7.))*$pi)) / $pi * 180.0;
}
sub tile2path
{
    my ($tilex, $tiley, $zoom) = @_;
    return "$zoom/$tilex/$tiley.png";
}


__END__

=head1 NAME

osmgnuplot.pl - Download OSM tiles, and make a gnuplot script to render them

=head1 SYNOPSIS

 $ osmgnuplot.pl --center 34.094719,-118.235779 --rad 300m --zoom 16
 Downloading http://tile.openstreetmap.org/16/11243/26158.png
 Downloading http://tile.openstreetmap.org/16/11244/26158.png
 Downloading http://tile.openstreetmap.org/16/11243/26159.png
 Downloading http://tile.openstreetmap.org/16/11244/26159.png
 Done! Gnuplot script 'montage_34.094719_-118.235779_300m_16.gp' uses the image 'montage_34.094719_-118.235779_300m_16.png'

 $ gnuplot -persist montage_34.094719_-118.235779_300m_16.gp
 [a gnuplot window pops up, showing OSM tiles]

=head1 DESCRIPTION

This script downloads OSM tiles, glues them together into a single image, and
generates a gnuplot script to render this image, aligned correctly to its
latitude, longitude (on the gnuplot y2 and x2 axes respectively). While this in
itself is not useful, the gnuplot script can be expanded to plot other things on
top of the map, to make it easy to visualize geospatial data. Example plots
appear here:

L<http://notes.secretsauce.net/notes/2015/08/16_least-convenient-location-in-los-angeles-from-koreatown.html>

The generated gnuplot script darkens the map a bit to make the extra stuff stand
out (C<attenuation> parameter in the resulting script).

The communication with the OSM tile server assumes some caching. If an
appropriately-named tile already exists on disk, the C<If-None-Match> header
field is used to send over the MD5 hash of the tile on disk. If the tile on the
server has the same hash, the server doesn't bother sending it over, which
results in bandwidth savings.

The OSM tiles have a nonlinear relationship between longitude and tile pixels.
The gnuplot script generated here applies the nonlinearity to the y2 axis, so
the plotted image is not distorted, but the axes are still showing the correct
data. A side-effect of this is that latitude is on the y2 axis and longitude is
on the x2 axis. For instance, to plot a file C<latlon.dat> containing
latitude,longitude columns with points on top of the stitched OSM tiles, do this:

  plot "montage_....png" ...., \
       "latlon.dat" using 2:1 with points axis x2y2

The C<"montage..."> stuff is generated by C<osmgnuplot.pl>, and the user would
add the C<"latlon.dat"> stuff.

Note that some versions of gnuplot have a minor bug, and you may see the following message:

 warning: could not confirm linked axis inverse mapping function

This is benign, and can be ignored

=head1 REQUIRED ARGUMENTS

=over

=item --center <lat>,<lon>

Center point

=for Euclid:
  lat.type: number
  lon.type: number

=item --rad <radius>

How far around the center to query. This must include units (support C<m>, C<km>
and C<miles>; no whitespace between the number and units).

=for Euclid:
  radius.type: /[0-9]+(?:\.[-9]*)?(?:miles?|km|m)/

=item --zoom <zoom>

The OSM zoom level

=for Euclid:
  zoom.type: integer, zoom > 0 && zoom <= 18

=for Euclid:
  radius.type: /[0-9]+(?:\.[-9]*)?(?:miles?|km|m)/

=back

=head1 OPTIONAL ARGUMENTS

=over

=item --serverpath <url>

The base URL to grab tiles from. We default to the OSM tile server:
C<http://tile.openstreetmap.org>

=for Euclid:
  url.type: string
  url.default: "https://tile.openstreetmap.org"

=item  --feedgnuplot

If given, generate options for feedgnuplot, instead of a gnuplot script.
Exclusive with --gnuplotlib

=item  --gnuplotlib

If given, generate options for gnuplotlib, instead of a gnuplot script.
Exclusive with --feedgnuplot

=back

=head1 DEPENDENCIES

I use non-core perl modules C<Getopt::Euclid> and C<LWP::UserAgent>. I also use
the C<montage> tool from C<imagemagick>. On a Debian box the following should be
sufficient:

 apt-get install libgetopt-euclid-perl libwww-perl imagemagick

=head1 REPOSITORY

L<https://github.com/dkogan/osmgnuplot>

=head1 AUTHOR

Dima Kogan, C<< <dima@secretsauce.net> >>

=head1 LICENSE AND COPYRIGHT

Copyright 2015 Dima Kogan.

This program is free software; you can redistribute it and/or modify it under
the terms of the Lesser General Public License version 3, as published by the
Free Software Foundation. Full text at http://www.gnu.org/licenses/lgpl.html
