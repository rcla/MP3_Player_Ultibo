<h1 align="center">
	MP3 Player with Ultibo
</h1>
<p align="center"><strong>Using libmad to decode the mp3 file.</strong></p>

<br></br>

## Usage

Based on the [20-PWMSound](https://github.com/ultibohub/Examples/tree/master/20-PWMSound) example (Pascal).

- Folder RPi3 (Raspberry Pi 3A/3B/Zero2).
- Folder RPi4 (Raspberry Pi 4B/400).
- You must compile the Ultibo project (Pascal).
- Copy the `test.mp3` file to the micro SD.

> Note: You can use another mp3 file, but be sure to change the name within the program.
> The mp3 file has been downloaded from this [site](https://github.com/sank29/Star-Wars).

> The included mad.pas file is only needed until the fpc package included with Ultibo is updated.
> It is recommended to work with the `develop` branch of Ultibo, as it includes the libmad static library.


<br></br>

## Program
- With the test.mp3 file, it reads it, decodes it, and obtains relevant information.
- Gets the duration of the song in hh:mm:ss.
- It is then played back via PWM with the output of the jack.

On screen displays:
```
The file size of test.mp3 is: 2105160 bytes
Read MP3 File OK

Decoding the mp3 file..

Duration: 00:02:11
Bitrate: 128000 bps
Number channels: 2
Sample Rate: 44100 hz
```

<br></br>

## Additional information
- Information [MAD: MPEG Audio Decoder](https://www.underbit.com/products/mad/)
- Official forum and solution to doubts from [Forum Ultibo](https://ultibo.org/forum/index.php).
- Ultibo examples and information [Ultibo Examples](https://github.com/ultibohub/Examples).
