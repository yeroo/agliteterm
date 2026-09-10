using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Pipes;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

public static class LiteConcurrencyProbe
{
    private static int checks;
    private static void Check(bool ok, string what)
    {
        if (!ok) throw new InvalidOperationException(what);
        Interlocked.Increment(ref checks);
    }
    public static JsonElement Call(string pipe, string cmd, string target = "", object args = null)
    {
        using var cancel = new CancellationTokenSource(10000);
        using var stream = new NamedPipeClientStream(".", pipe, PipeDirection.InOut, PipeOptions.Asynchronous);
        stream.ConnectAsync(cancel.Token).GetAwaiter().GetResult();
        var bytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new { cmd, target, args = args ?? new { } }) + "\n");
        stream.WriteAsync(bytes.AsMemory(), cancel.Token).AsTask().GetAwaiter().GetResult();
        using var reader = new StreamReader(stream, Encoding.UTF8);
        var line = reader.ReadLineAsync(cancel.Token).AsTask().GetAwaiter().GetResult();
        using var reply = JsonDocument.Parse(line ?? throw new IOException("Control pipe closed before reply"));
        Check(reply.RootElement.GetProperty("ok").GetBoolean(), cmd + ": " + line);
        return reply.RootElement.GetProperty("result").Clone();
    }
    private static HashSet<string> Snapshot(string pipe)
    {
        var ids = new HashSet<string>();
        foreach (var ws in Call(pipe, "tree").GetProperty("workspaces").EnumerateArray())
        {
            string identity = ws.GetProperty("id").GetString();
            Check(ids.Add("workspace:" + identity + ":" + ws.GetProperty("name").GetString()), "Tree has duplicate workspace identity");
            foreach (var session in ws.GetProperty("sessions").EnumerateArray())
            {
                string sessionId = session.GetProperty("id").GetString();
                Check(ids.Add("session:" + sessionId), "Tree has duplicate session identity");
                ids.Add("placement:" + sessionId + ":" + identity);
            }
        }
        return ids;
    }
    public static int Run(string pipe)
    {
        checks = 0;
        var baseline = Snapshot(pipe);
        Check(baseline.Any(id => id.StartsWith("session:")), "Baseline pane must exist");
        var jobs = new List<Task>();
        for (int worker = 0; worker < 2; ++worker)
        {
            int own = worker;
            jobs.Add(Task.Run(() => {
                for (int n = 0; n < 4; ++n)
                {
                    string name = "concurrent-" + own + "-" + n + "-" + new string('x', 128);
                    string id = Call(pipe, "session.new", "", new Dictionary<string, object> {
                        ["command"] = "cmd.exe /d /q", ["workspace"] = "0", ["name"] = name, ["no-select"] = true
                    }).GetString();
                    Call(pipe, "session.rename", id, new { name = name + "-renamed" });
                    Call(pipe, "session.flag", id, new { op = "on" });
                    Call(pipe, "session.move", id, new { dir = "up" });
                    Call(pipe, "session.select", id);
                    Call(pipe, "session.write", id, new { text = "DISPLAY-ONLY-CONCURRENCY\r\n" });
                    Call(pipe, "session.text", id);
                    Call(pipe, "session.close", id);
                }
            }));
        }
        jobs.Add(Task.Run(() => {
            for (int n = 0; n < 3; ++n)
            {
                string id = Call(pipe, "workspace.new", "", new { name = "concurrent-workspace-" + n }).GetString();
                Call(pipe, "workspace.rename", id, new { name = "renamed-workspace-" + n });
                Call(pipe, "workspace.select", "0");
                Call(pipe, "workspace.delete", id);
            }
        }));
        jobs.Add(Task.Run(() => { for (int n = 0; n < 40; ++n) { Snapshot(pipe); Thread.Sleep(20); } }));
        // WhenAll settles every worker even when one fails; no queued writes outlive the fixture.
        Task.WhenAll(jobs).GetAwaiter().GetResult();
        Check(baseline.SetEquals(Snapshot(pipe)), "Concurrent actions changed baseline workspaces, panes, or their placement");
        return checks;
    }
}
