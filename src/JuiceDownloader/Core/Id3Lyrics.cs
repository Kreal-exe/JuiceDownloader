using System.Text;

namespace JuiceDownloader.Core;

/// <summary>
/// Reads and writes the USLT frame of an MP3's ID3v2 tag, leaving every other frame exactly as it was. The new file is
/// written beside the old one and moved over it, so a failure cannot leave a damaged track.
/// </summary>
public static class Id3Lyrics
{
    private const int HeaderSize = 10;
    private const int Padding = 2048;
    private const int ContainerProbe = 8;

    public static bool CanTag(string file) => string.Equals(Path.GetExtension(file), ".mp3", StringComparison.OrdinalIgnoreCase) && IsWritableMp3(file);

    private static bool IsWritableMp3(string file)
    {
        using var stream = File.OpenRead(file);
        var header = new byte[HeaderSize];
        var read = stream.ReadAtLeast(header, HeaderSize, throwOnEndOfStream: false);
        if (read < HeaderSize || !IsTag(header)) return !IsOtherContainer(header.AsSpan(0, read));
        if (header[3] is not (3 or 4)) return false;
        stream.Position = HeaderSize + ((long)header[6] << 21 | (long)header[7] << 14 | (long)header[8] << 7 | header[9]);
        var start = new byte[ContainerProbe];
        return !IsOtherContainer(start.AsSpan(0, stream.ReadAtLeast(start, ContainerProbe, throwOnEndOfStream: false)));
    }

    // Some files in the archive are named .mp3 but hold another format, and a tag in front of those stops them playing.
    private static bool IsOtherContainer(ReadOnlySpan<byte> h) =>
        h.Length >= 8 && h[4..8].SequenceEqual("ftyp"u8)
        || h.Length >= 4 && (h[..4].SequenceEqual("RIFF"u8) || h[..4].SequenceEqual("OggS"u8) || h[..4].SequenceEqual("fLaC"u8)
                             || h[..4].SequenceEqual((byte[])[0x1A, 0x45, 0xDF, 0xA3]));

    public static bool Has(string file)
    {
        using var stream = File.OpenRead(file);
        var tag = ReadTag(stream);
        return tag is not null && tag.Frames.Any(f => f.Id == "USLT");
    }

    public static void Write(string file, string lyrics)
    {
        byte[] output;
        long audioStart;
        using (var stream = File.OpenRead(file))
        {
            var tag = ReadTag(stream);
            var version = tag?.Version ?? (byte)3;
            audioStart = tag?.EndOffset ?? 0;
            using var body = new MemoryStream();
            foreach (var frame in tag?.Frames ?? [])
            {
                if (frame.Id == "USLT") continue;
                body.Write(frame.Raw);
            }
            WriteFrame(body, version, "USLT", LyricsBody(version, lyrics));
            body.Write(new byte[Padding]);

            var size = (int)body.Length;
            output = new byte[HeaderSize + size];
            "ID3"u8.CopyTo(output);
            output[3] = version;
            output[6] = (byte)((size >> 21) & 0x7F);
            output[7] = (byte)((size >> 14) & 0x7F);
            output[8] = (byte)((size >> 7) & 0x7F);
            output[9] = (byte)(size & 0x7F);
            body.Position = 0;
            body.ReadExactly(output, HeaderSize, size);
        }

        var tmp = file + ".tagging";
        try
        {
            using (var input = File.OpenRead(file))
            using (var result = File.Create(tmp))
            {
                result.Write(output);
                input.Position = audioStart;
                input.CopyTo(result);
            }
            File.Move(tmp, file, overwrite: true);
        }
        finally
        {
            if (File.Exists(tmp)) File.Delete(tmp);
        }
    }

    private sealed record Frame(string Id, byte[] Raw);
    private sealed record Tag(byte Version, long EndOffset, List<Frame> Frames);

    private static bool IsTag(ReadOnlySpan<byte> h) =>
        h[0] == 'I' && h[1] == 'D' && h[2] == '3' && h[3] != 0xFF && h[4] != 0xFF && h[6] < 0x80 && h[7] < 0x80 && h[8] < 0x80 && h[9] < 0x80;

    private static Tag? ReadTag(Stream stream)
    {
        var header = new byte[HeaderSize];
        if (stream.ReadAtLeast(header, HeaderSize, throwOnEndOfStream: false) < HeaderSize || !IsTag(header)) return null;

        var version = header[3];
        if (version is not (3 or 4)) throw new InvalidDataException("Only ID3v2.3 and v2.4 tags can be rewritten.");
        var flags = header[5];
        var size = (header[6] << 21) | (header[7] << 14) | (header[8] << 7) | header[9];
        if (size > stream.Length - HeaderSize) throw new InvalidDataException("The tag is longer than the file.");
        var end = HeaderSize + (long)size + ((flags & 0x10) != 0 && version == 4 ? HeaderSize : 0);

        var body = new byte[size];
        stream.ReadExactly(body);
        if (version == 3 && (flags & 0x80) != 0) body = RemoveUnsync(body);

        var pos = 0;
        if ((flags & 0x40) != 0 && body.Length >= 4)
        {
            // The extended header is dropped: it holds a checksum or restrictions for the tag as it was.
            var ext = version == 4
                ? (body[0] << 21) | (body[1] << 14) | (body[2] << 7) | body[3]
                : ((body[0] << 24) | (body[1] << 16) | (body[2] << 8) | body[3]) + 4;
            if (ext < 0 || ext > body.Length) throw new InvalidDataException("Damaged extended header.");
            pos = ext;
        }

        var frames = new List<Frame>();
        while (pos + HeaderSize <= body.Length)
        {
            var id = body.AsSpan(pos, 4);
            var valid = true;
            foreach (var c in id) valid &= c is >= (byte)'A' and <= (byte)'Z' or >= (byte)'0' and <= (byte)'9';
            if (!valid) break; // padding, or something this reader should leave out of the rewrite

            long length = version == 4
                ? (body[pos + 4] << 21) | (body[pos + 5] << 14) | (body[pos + 6] << 7) | body[pos + 7]
                : ((long)body[pos + 4] << 24) | ((long)body[pos + 5] << 16) | ((long)body[pos + 6] << 8) | body[pos + 7];
            if (length <= 0 || pos + HeaderSize + length > body.Length) break;

            frames.Add(new Frame(Encoding.ASCII.GetString(id), body.AsSpan(pos, HeaderSize + (int)length).ToArray()));
            pos += HeaderSize + (int)length;
        }
        return new Tag(version, end, frames);
    }

    private static byte[] RemoveUnsync(byte[] data)
    {
        var result = new byte[data.Length];
        var n = 0;
        for (var i = 0; i < data.Length; i++)
        {
            result[n++] = data[i];
            if (data[i] == 0xFF && i + 1 < data.Length && data[i + 1] == 0) i++;
        }
        return result[..n];
    }

    private static byte[] LyricsBody(byte version, string lyrics)
    {
        using var body = new MemoryStream();
        if (version == 4)
        {
            body.WriteByte(3); // UTF-8
            body.Write("eng"u8);
            body.WriteByte(0); // empty description
            body.Write(Encoding.UTF8.GetBytes(lyrics));
        }
        else
        {
            body.WriteByte(1); // UTF-16 with a byte order mark, the only full Unicode ID3v2.3 has
            body.Write("eng"u8);
            var bom = new byte[] { 0xFF, 0xFE };
            body.Write(bom);
            body.Write(new byte[2]);
            body.Write(bom);
            body.Write(Encoding.Unicode.GetBytes(lyrics));
        }
        return body.ToArray();
    }

    private static void WriteFrame(Stream to, byte version, string id, byte[] content)
    {
        to.Write(Encoding.ASCII.GetBytes(id));
        var n = content.Length;
        if (version == 4)
        {
            to.WriteByte((byte)((n >> 21) & 0x7F));
            to.WriteByte((byte)((n >> 14) & 0x7F));
            to.WriteByte((byte)((n >> 7) & 0x7F));
            to.WriteByte((byte)(n & 0x7F));
        }
        else
        {
            to.WriteByte((byte)(n >> 24));
            to.WriteByte((byte)(n >> 16));
            to.WriteByte((byte)(n >> 8));
            to.WriteByte((byte)n);
        }
        to.WriteByte(0);
        to.WriteByte(0);
        to.Write(content);
    }
}
