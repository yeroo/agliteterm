using System;
using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
public static class LiteOmpOracle {
    public static JsonElement Call(string pipe,string cmd,string target,string argsJson) {
        using var cancel=new CancellationTokenSource(12000);
        using var stream=new NamedPipeClientStream(".",pipe,PipeDirection.InOut,PipeOptions.Asynchronous);
        stream.ConnectAsync(cancel.Token).GetAwaiter().GetResult();
        using var arguments=JsonDocument.Parse(argsJson??"{}");
        var bytes=Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new {cmd,target,args=arguments.RootElement})+"\n");
        stream.WriteAsync(bytes.AsMemory(),cancel.Token).AsTask().GetAwaiter().GetResult();
        using var reader=new StreamReader(stream,Encoding.UTF8);
        var line=reader.ReadLineAsync(cancel.Token).AsTask().GetAwaiter().GetResult();
        using var reply=JsonDocument.Parse(line??throw new IOException("No control reply"));
        return reply.RootElement.Clone();
    }
    public static Task<JsonElement> Begin(string pipe,string cmd,string target,string argsJson) => Task.Run(()=>Call(pipe,cmd,target,argsJson));
}
