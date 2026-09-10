using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Pipes;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Threading;

// Read-only wire oracle: only Hello/List. All mutations go through the actual Lite client.
public static class LiteCreationHost
{
    static NamedPipeClientStream Open(string pipe, CancellationToken token)
    {
        var stream = new NamedPipeClientStream(".", pipe, PipeDirection.InOut, PipeOptions.Asynchronous);
        try { stream.ConnectAsync(token).GetAwaiter().GetResult(); return stream; }
        catch { stream.Dispose(); throw; }
    }
    public static JsonElement Call(string pipe, string cmd, string target, object args)
    {
        using var deadline = new CancellationTokenSource(10000);
        using var stream = Open(pipe, deadline.Token);
        byte[] data = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new { cmd, target, args = args ?? new { } }) + "\n");
        stream.WriteAsync(data.AsMemory(), deadline.Token).AsTask().GetAwaiter().GetResult();
        using var reader = new StreamReader(stream, Encoding.UTF8);
        string line = reader.ReadLineAsync(deadline.Token).AsTask().GetAwaiter().GetResult();
        using var reply = JsonDocument.Parse(line ?? throw new IOException("No control reply"));
        if (!reply.RootElement.GetProperty("ok").GetBoolean()) throw new IOException(line);
        return reply.RootElement.GetProperty("result").Clone();
    }
    static void Read(NamedPipeClientStream stream, byte[] bytes, CancellationToken token)
    {
        int pos = 0;
        while (pos < bytes.Length) {
            int n = stream.ReadAsync(bytes.AsMemory(pos), token).AsTask().GetAwaiter().GetResult();
            if (n == 0) throw new IOException("Incomplete host reply"); pos += n;
        }
    }
    static ulong Varint(byte[] data, ref int pos)
    {
        ulong value = 0;
        for (int shift = 0; shift < 64 && pos < data.Length; shift += 7) {
            byte b = data[pos++]; value |= (ulong)(b & 127) << shift;
            if ((b & 128) == 0) return value;
        }
        throw new IOException("Invalid protobuf varint");
    }
    static List<(int tag, ulong number, byte[] data)> Fields(byte[] bytes)
    {
        var fields = new List<(int, ulong, byte[])>(); int pos = 0;
        while (pos < bytes.Length) {
            ulong key = Varint(bytes, ref pos); int tag = checked((int)(key >> 3));
            if (tag == 0) throw new IOException("Invalid protobuf tag");
            if ((key & 7) == 0) fields.Add((tag, Varint(bytes, ref pos), null));
            else if ((key & 7) == 2) {
                int size = checked((int)Varint(bytes, ref pos));
                if (size > bytes.Length - pos) throw new IOException("Invalid protobuf length");
                fields.Add((tag, 0, bytes.AsSpan(pos, size).ToArray())); pos += size;
            } else throw new IOException("Unexpected oracle wire type");
        }
        return fields;
    }
    static byte[] Query(string pipe, byte[] request, int body)
    {
        using var deadline = new CancellationTokenSource(10000);
        using var stream = Open(pipe, deadline.Token);
        byte[] frame = BitConverter.GetBytes(request.Length).Concat(request).ToArray();
        stream.WriteAsync(frame.AsMemory(), deadline.Token).AsTask().GetAwaiter().GetResult();
        byte[] prefix = new byte[4]; Read(stream, prefix, deadline.Token);
        int size = BitConverter.ToInt32(prefix); if (size < 1 || size > 1048576) throw new IOException("Invalid frame size");
        byte[] reply = new byte[size]; Read(stream, reply, deadline.Token);
        var fields = Fields(reply);
        if (fields.Single(x => x.tag == 1).number != 1) throw new IOException("Host query refused");
        return fields.Single(x => x.tag == body).data;
    }
    public static uint Revision(string pipe) => checked((uint)Fields(Query(pipe, new byte[] { 10, 2, 8, 2 }, 3)).SingleOrDefault(x => x.tag == 3).number);
    public sealed class Pane { public string Id; public string Ticket; public int Pid; public bool Attached; }
    public static Pane[] List(string pipe) => Fields(Query(pipe, new byte[] { 58, 0 }, 6)).Where(x => x.tag == 1).Select(x => {
        var fields = Fields(x.data);
        string Text(int tag) => Encoding.UTF8.GetString(fields.SingleOrDefault(f => f.tag == tag).data ?? Array.Empty<byte>());
        return new Pane { Id = Text(1), Ticket = Text(9), Pid = checked((int)fields.SingleOrDefault(f => f.tag == 4).number), Attached = fields.SingleOrDefault(f => f.tag == 8).number == 1 };
    }).ToArray();
}
