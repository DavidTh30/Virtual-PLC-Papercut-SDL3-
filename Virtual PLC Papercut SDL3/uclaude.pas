unit uClaude;

{ Claude in the program editor: a conversation with the Messages API (claude-opus-5-5) and a tool
  loop that lets Claude read and write the project, compile it and read live values.

  Loop       Ask -> a request on a worker thread (uClaudeHttp) -> Poll (each UI frame) takes the
             answer: its content goes back into the conversation unchanged (append only), text is
             shown, tool_use blocks run here on the main thread (the project is not thread safe),
             their results go out in one user message -> the next request, until end_turn
  Safety     before the first change of a request the whole project is kept (Undo), downloading
             asks the user first, a refusal or a cut-off answer runs no tools
  Request    max_tokens 16000 (non streaming), effort high, adaptive thinking (the model default),
             fallbacks "default" (server-side fallback on a classifier decline), prompt caching }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, StrUtils, DateUtils, TypInfo, fpjson, jsonparser, uPlcTypes, uPlcProject, uPlcCompiler, uPlcRuntime,
  uClaudeHttp, uFbd;

const
  ClaudeModel = 'claude-opus-5-5';
  MaxToolLoops = 30;

type
  TChatKind = (ckUser, ckAssistant, ckTool, ckInfo, ckError);
  TChatEntry = record
    Kind: TChatKind;
    Text: string;
    Files: string;      // the user's attachments: one 'name (kind, size)' per line
  end;
  { a file for Claude, ready for the request: an image (base64 PNG / JPEG), a PDF (base64) or text }
  TChatKindOfFile = (cfImage, cfPdf, cfText);
  TChatAttachment = record
    Name: string;
    Kind: TChatKindOfFile;
    Media: string;      // image/png, image/jpeg, application/pdf, text/plain
    Data: string;       // base64 (image, PDF) or the UTF-8 text
    Bytes: Int64;       // the size of the file as loaded (for the chip)
  end;
  TChatAttachments = array of TChatAttachment;
  TAgentState = (asIdle, asWaiting, asConfirm);
  TAgentProc = procedure of object;
  TAgentCompiled = procedure(P: TCProgram) of object;
  TAgentDirty = function: Boolean of object;

  { TClaudeAgent }

  TClaudeAgent = class
  private
    FMessages: TJSONArray;          // the conversation (append only)
    FReq: TClaudeRequest;
    FPending: TJSONArray;           // tool_use blocks of the answer being worked off
    FPendIx: Integer;
    FResults: TJSONArray;           // their tool_result blocks so far
    FSnap: string;                  // the project before this request's first change
    FSnapTaken: Boolean;
    FLoops: Integer;
    FSent: TDateTime;
    FToolsJson: string;
    FDelayUntil: TDateTime;         // read_values with wait_ms: the tools go on after this
    FDelayDone: Boolean;
    procedure AddChat(K: TChatKind; const S: string);
    procedure Send;
    procedure TakeAnswer(const S: string);
    procedure WorkTools;
    procedure FinishTools;
    procedure Snapshot;
    function RunTool(const Name: string; Inp: TJSONObject; out IsErr: Boolean): string;
    function FindBlockRef(const S: string): TBlock;
    function BlockJson(B: TBlock): TJSONObject;
    function CompileJson(OnlyBlock: TBlock): TJSONObject;
  public
    Project: TPlcProject;
    Rt: TPlcRuntime;
    Chat: array of TChatEntry;
    State: TAgentState;
    ConfirmText: string;
    Context: string;                // what the editor shows (set by the UI before Ask)
    InTokens, OutTokens: Int64;
    OnChanged: TAgentProc;          // the project was changed (mark dirty)
    OnReloaded: TAgentProc;         // the project was replaced by the snapshot (drop pointers)
    OnDownload: TAgentProc;         // download the compiled program (the UI's Download)
    OnCompiled: TAgentCompiled;     // show the compile messages
    IsDirty: TAgentDirty;           // the offline program differs from the downloaded one
    constructor Create;
    destructor Destroy; override;
    function HasKey: Boolean;
    procedure Ask(const Text: string); overload;
    procedure Ask(const Text: string; const Files: TChatAttachments); overload;
    procedure Poll;
    procedure Confirm(Allow: Boolean);
    procedure Cancel;
    procedure NewChat;
    function CanUndo: Boolean;
    procedure UndoChanges;
    function Busy: Boolean;
    function WaitSeconds: Double;
    function ToolsJson: TJSONArray;
    function SystemPrompt: string;
    { for the tests: run one tool directly (the result text, IsErr) }
    function TestTool(const Name, InputJson: string; out IsErr: Boolean): string;
  end;

implementation

const
  ToolDefs =
    '[' +
    '{"name":"get_project","description":"The overview of the whole project: CPU, blocks (OB/FC/FB with their networks), data blocks with variables, PLC data types, tags, and whether it compiles. Call this first when you start working on a request.","input_schema":{"type":"object","properties":{}}},' +
    '{"name":"get_block","description":"One block in full: its interface (Input, Output, InOut, Static, Temp, Return) and every network with its language and code (SCL / STL text, LAD as a cell grid). Call this before you change a block.","input_schema":{"type":"object","properties":{"block":{"type":"string","description":"OB1, FC2, FB1 or the block name"}},"required":["block"]}},' +
    '{"name":"write_network","description":"Writes one network of a block: replaces network n (1-based) or appends a new one when network is 0 or missing. SCL / STL: the whole code in code. LAD: the cells (see the system prompt). Returns the compile messages of the block: fix every error.","input_schema":{"type":"object","properties":{' +
      '"block":{"type":"string"},"network":{"type":"integer","description":"1-based; 0 or missing appends"},' +
      '"language":{"type":"string","enum":["SCL","STL","LAD","FBD","CFC"]},"title":{"type":"string"},"comment":{"type":"string"},' +
      '"nodes":{"type":"array","description":"FBD / CFC boxes (see the system prompt)","items":{"type":"object"}},' +
      '"code":{"type":"string","description":"SCL or STL code, lines separated by \\n"},' +
      '"cells":{"type":"array","description":"LAD cells","items":{"type":"object","properties":{"r":{"type":"integer"},"c":{"type":"integer"},"e":{"type":"string"},"op":{"type":"string"},"p":{"type":"array","items":{"type":"string"}},"args":{"type":"array","items":{"type":"string"}},"down":{"type":"boolean"},"type":{"type":"string"},"cmp":{"type":"string"},"type2":{"type":"string"}},"required":["r","c","e"]}}},' +
      '"required":["block","language"]}},' +
    '{"name":"delete_network","description":"Deletes network n (1-based) of a block.","input_schema":{"type":"object","properties":{"block":{"type":"string"},"network":{"type":"integer"}},"required":["block","network"]}},' +
    '{"name":"create_block","description":"Creates an FC or an FB (without networks: write them with write_network). For an FB, instance_db creates its instance DB too.","input_schema":{"type":"object","properties":{' +
      '"kind":{"type":"string","enum":["FC","FB"]},"number":{"type":"integer","description":"optional: the next free number"},"name":{"type":"string"},"comment":{"type":"string"},' +
      '"interface":{"type":"array","items":{"type":"object","properties":{"section":{"type":"string","enum":["Input","Output","InOut","Static","Temp","Return"]},"name":{"type":"string"},"type":{"type":"string"},"default":{"type":"string"},"comment":{"type":"string"}},"required":["section","name","type"]}},' +
      '"instance_db":{"type":"string","description":"FB only: the name of a new instance DB"}},"required":["kind","name"]}},' +
    '{"name":"set_interface","description":"Replaces the whole interface of an FC / FB / OB (an OB has only Temp, an FC no Static, an FB no Return).","input_schema":{"type":"object","properties":{"block":{"type":"string"},' +
      '"interface":{"type":"array","items":{"type":"object","properties":{"section":{"type":"string","enum":["Input","Output","InOut","Static","Temp","Return"]},"name":{"type":"string"},"type":{"type":"string"},"default":{"type":"string"},"comment":{"type":"string"}},"required":["section","name","type"]}}},"required":["block","interface"]}},' +
    '{"name":"add_db_variables","description":"Adds variables to a global data block (a variable that exists already gets the new type / start value). Creates the DB when it does not exist.","input_schema":{"type":"object","properties":{"db":{"type":"string","description":"the DB name"},"number":{"type":"integer","description":"for a new DB: optional, the next free number"},' +
      '"variables":{"type":"array","items":{"type":"object","properties":{"name":{"type":"string"},"type":{"type":"string"},"start":{"type":"string"},"comment":{"type":"string"}},"required":["name","type"]}}},"required":["db","variables"]}},' +
    '{"name":"add_tags","description":"Adds PLC tags (symbols) to the tag table; a tag that exists already gets the new type / address.","input_schema":{"type":"object","properties":{"tags":{"type":"array","items":{"type":"object","properties":{"name":{"type":"string"},"type":{"type":"string"},"address":{"type":"string"},"comment":{"type":"string"}},"required":["name","type","address"]}}},"required":["tags"]}},' +
    '{"name":"compile","description":"Compiles the whole project and returns every error and warning (block, network, line). Call it after your changes and before you finish.","input_schema":{"type":"object","properties":{}}},' +
    '{"name":"read_values","description":"Reads live values from the simulated CPU (it must be in RUN with the current program downloaded): absolute addresses, \"Tags\", \"DB\".Var. Use it to debug: what the inputs, outputs and variables really are. wait_ms waits first (up to 10000), e.g. for a timer to run out after set_inputs.","input_schema":{"type":"object","properties":{"operands":{"type":"array","items":{"type":"string"}},"wait_ms":{"type":"integer","description":"0..10000: wait before reading"}},"required":["operands"]}},' +
    '{"name":"set_inputs","description":"Operates the simulated inputs, like the user on the I/O screen: digital inputs (bits of I, e.g. %I0.5 or \"Start_PB\") true / false, analog inputs (IW words of the analog channels) 0..27648. Use it to test the program: press a button, read_values, release it. A push button pressed stays pressed until you set it false again.","input_schema":{"type":"object","properties":{"inputs":{"type":"object","description":"operand: value, e.g. {\"%I0.5\": true, \"%IW64\": 13824}","additionalProperties":{"type":["boolean","integer"]}}},"required":["inputs"]}},' +
    '{"name":"get_diagnostics","description":"The CPU mode, why it stopped, and the last entries of the diagnostic buffer (programming errors such as an array index out of range, a cycle time overrun).","input_schema":{"type":"object","properties":{}}},' +
    '{"name":"download_and_run","description":"Compiles, downloads the program to the simulated CPU and switches it to RUN. The user is asked first and may say no. Use it when you need live values of new code.","input_schema":{"type":"object","properties":{}}}' +
    ']';

{ TClaudeAgent }

constructor TClaudeAgent.Create;
begin
  inherited Create;
  FMessages := TJSONArray.Create;
  FToolsJson := ToolDefs;
end;

destructor TClaudeAgent.Destroy;
begin
  Cancel;
  FMessages.Free;
  FPending.Free;
  FResults.Free;
  inherited Destroy;
end;

function TClaudeAgent.HasKey: Boolean;
var
  Src: string;
begin
  Result := ClaudeApiKey(Src) <> '';
end;

procedure TClaudeAgent.AddChat(K: TChatKind; const S: string);
begin
  SetLength(Chat, Length(Chat) + 1);
  Chat[High(Chat)].Kind := K;
  Chat[High(Chat)].Text := S;
end;

function TClaudeAgent.ToolsJson: TJSONArray;
begin
  Result := GetJSON(FToolsJson) as TJSONArray;
end;

function TClaudeAgent.SystemPrompt: string;
begin
  Result :=
    'You are the programming assistant built into Virtual PLC, a simulator of Siemens S7-300, S7-400, S7-1200 and ' +
    'S7-1500 CPUs. You work in the program editor together with the user: you read and write the user''s blocks ' +
    'through the tools, compile them, and read live values from the simulated CPU to debug. Answer in the language ' +
    'the user writes in, briefly; name the block and network you changed and why.' + LineEnding + LineEnding +
    'How to work' + LineEnding +
    '- Look before you change: get_project, then get_block for the blocks the request touches.' + LineEnding +
    '- Change the project only through the tools. write_network returns the compile messages of the block: fix ' +
    'every error before you finish, and call compile at the end of a change.' + LineEnding +
    '- Keep the user''s names, style and comments; change what the request needs, nothing else. Put symbols in the ' +
    'tag table or a DB instead of bare addresses when you add new signals, and write a short title / comment for ' +
    'networks you add.' + LineEnding +
    '- To debug, read live values with read_values and get_diagnostics. They need the CPU in RUN with the current ' +
    'program downloaded: the user downloads with F8, or you call download_and_run (the user is asked first). ' +
    'Test like a commissioning engineer: operate the simulated inputs with set_inputs (press, release, NC buttons ' +
    'are TRUE when not pressed), read_values (wait_ms for timers), and put the inputs back to a safe state at the ' +
    'end. Only the simulator''s inputs change, never real hardware.' + LineEnding +
    '- The user can undo all your changes of one request with one button, so make complete, consistent edits.' + LineEnding +
    LineEnding +
    'What this simulator understands (a subset of STEP 7 / TIA Portal)' + LineEnding +
    'Operands: I0.0 Q4.0 M10.1 MB5 MW20 MD24 IW256 (peripheral PIW/PQW on the 300/400, :P on the 1200/1500), ' +
    'DB1.DBX0.0 DB1.DBW2 DB1.DBD4, T 1, C 1; the S7-1200/1500 write %I0.0, %MW20. Symbols: "Tag", "DB".Var, ' +
    '"DB".Arr[3], "DB".Arr[#i].Member, "DB".Struct.Member; inside an FB / FC: #Param, #Static, #Temp. Optimized DBs ' +
    '(1200/1500) allow symbolic access only.' + LineEnding +
    'Types: Bool Byte Word DWord Char Int DInt Real Time S5Time Date Time_Of_Day IEC_TIMER IEC_COUNTER (the ' +
    '1200/1500 also SInt USInt UInt UDInt), Array[lo..hi] of T, PLC data types "Name" (the 300/400 also UDTn). ' +
    'Constants: 5, 1.5, TRUE, T#5S, S5T#2S, 16#FF, C#10.' + LineEnding +
    'Blocks: OB1 (main cycle), OB35 (300/400) or OB30 (1200/1500) cyclic interrupt, OB100 startup, FCs, FBs with ' +
    'instance DBs or multi-instances (a Static of an FB type).' + LineEnding +
    'SCL (all families): VAR_TEMP name : Type; END_VAR at the top of a network (or the block interface Temp); ' +
    ':= ; IF .. THEN .. ELSIF .. ELSE .. END_IF; CASE x OF 1: ..; 2..5: ..; ELSE .. END_CASE; FOR #i := 0 TO 9 BY 1 ' +
    'DO .. END_FOR; WHILE .. DO .. END_WHILE; REPEAT .. UNTIL .. END_REPEAT; EXIT; CONTINUE; RETURN; REGION name .. ' +
    'END_REGION; // and (* *) comments. Operators: ** NOT * / MOD + - < > <= >= = <> AND & XOR OR. Functions: ' +
    'ABS SQRT SQR LN LOG EXP SIN COS TAN ASIN ACOS ATAN TRUNC ROUND MIN MAX LIMIT SEL NORM_X SCALE_X SHL SHR ROL ROR ' +
    'and <type>_TO_<type> conversions. IEC timers / counters on IEC_TIMER / IEC_COUNTER variables: ' +
    '"DB".T.TON(IN := x, PT := T#5S, Q => y, ET => t) (also TOF TP TONR, CTU CTD CTUD with CU CD R LD PV, Q QU QD ' +
    'CV). FB calls "Inst_DB"(In := x, Out => y, Io := z) and #inst(..); FC calls "Fc"(a := 1, b => #x) (every ' +
    'parameter must be given; InOuts need a variable of the same type) and r := "Fc"(..) for an FC with a Return ' +
    'value (#Ret_Val inside the FC). a := b copies whole structs / arrays of the same type. Type rules like TIA: ' +
    'REAL to INT needs REAL_TO_INT, conditions must be BOOL, integer literals are DINT, INT wraps at 16 bit.' + LineEnding +
    'STL (300/400/1500, not the 1200): one instruction per line, // comments, labels "L1:". A AN O ON X XN A( O( ) ' +
    '= S R NOT SET CLR FP FN; L T; +I -I *I /I +D -D *D /D MOD +R -R *R /R; ==I <>I >I <I >=I <=I (also D, R); ' +
    'ITD DTR RND TRUNC ITB BTI DTB BTD INVI NEGI; AW OW XOW AD OD XOD SLW SRW SLD SRD RLD RRD; JU JC JCN JZ JN JP ' +
    'JM JMZ JPZ JUO LOOP; SD SE SP SS SF T n with L S5T#..; CU CD S R L C n; OPN DB n; CALL FCn (or CALL FB1, DB2 / ' +
    'CALL "Inst_DB") followed by one parameter line per parameter "Name := operand"; BE BEC BEU NOP 0; TAK PUSH POP ' +
    'ENT LEAVE (400 only).' + LineEnding +
    'LAD: a grid of cells, rows 0..7, columns 0..31 (8 show at a time; it grows to the right). Power flows from the ' +
    'left rail through each row to the right; a row is one series path, so fill the gap up to the coil with "wire" ' +
    'cells (an empty cell breaks the path). "down": true on a cell is a vertical link on its right edge to the row ' +
    'below: parallel branches open and close there (a self-holding contact: row 0 {r:0,c:0,e:"no",op:"\"Start\"",' +
    'down:true}, {r:0,c:1,e:"nc",op:"\"Stop\""}, wires, {r:0,c:7,e:"coil",op:"\"Motor\""}, row 1 {r:1,c:0,e:"no",' +
    'op:"\"Motor\""}). Cell e: wire, no, nc, p / n (edge contacts, p:[edge memory bit]), not, coil, ncoil, set, ' +
    'reset; IEC boxes (op = the IEC_TIMER / IEC_COUNTER variable): ton tof tp (p:[PT, ET]), tonr (p:[PT, R, ET]), ' +
    'ctu (p:[PV, R, CV]), ctd (p:[PV, LD, CV]), ctud (p:[PV, CD, R, LD, CV]); S5 timers (300/400, op = T n, p:[S5T#..]): ' +
    'sd se sp ss sf; counters cu cd sc (op = C n, sc p:[C#..]); boxes with type (Int, DInt, Real ..): cmp (cmp "==" ' +
    '"<>" ">" "<" ">=" "<=", p:[IN1, IN2]), inrange outrange (p:[MIN, VAL, MAX]), move (p:[IN, OUT1]), add sub mul div ' +
    '(p:[IN1, IN2, OUT]), normx scalex (p:[MIN, VALUE, MAX, OUT]); converters conv (p:[IN, OUT], type = IN, type2 = OUT, ' +
    'e.g. Int to Real), round trunc ceil floor (p:[IN, OUT], IN Real, type2 = the integer OUT, e.g. DInt); call (op = FCn / "Fc" or an instance DB "Inst_DB"; args = the operands of its ' +
    'parameters in the order Input, InOut, Output, Return). A box takes two columns when the next cell is empty.' + LineEnding +
    'FBD and CFC (all families): a network of boxes, write_network with "nodes": [{"id":1,"box":"and","in":[{"pin":"IN1",' +
    '"op":"\"Start\""},{"pin":"IN2","op":"\"Stop\"","neg":true}]},{"id":2,"box":"assign","inst":"\"Motor\"","in":[{"pin":"IN",' +
    '"from":"1.Q"}]}]. An input pin has "op" (an operand / a constant) or "from":"<id>.<output pin>" (a wire), "neg":true ' +
    'negates it; an output pin may have "op" (it writes the operand). "inst": the operand / instance / block above the box. ' +
    'Boxes and pins: and or xor (IN1, IN2, IN3 .. ; Q), assign set reset (inst = the operand; IN), p n (inst = edge memory ' +
    'bit; IN; Q), rtrig ftrig (inst; CLK; Q), sr (S1, R; Q1) rs (S, R1; Q1), ton tof tp (inst = IEC_TIMER / TON_TIME ..; IN, PT; ' +
    'Q, ET), tonr (IN, R, PT), ctu (CU, R, PV; Q, CV) ctd (CD, LD, PV) ctud (CU, CD, R, LD, PV; QU, QD, CV), cmp ("cmp":"==" ' +
    '"<>" ">" "<" ">=" "<=", "type"; IN1, IN2; Q), inrange outrange (MIN, VAL, MAX; Q), with "type" and an optional EN: add sub ' +
    'mul div mod expt (IN1, IN2; OUT), neg abs sqr sqrt exp ln sin cos tan asin acos atan frac (IN; OUT), inc dec (inst), ' +
    'move (IN; OUT1), conv round trunc ceil floor (IN; OUT, "type2" = the OUT type), normx scalex (MIN, VALUE, MAX; OUT), ' +
    'sel (G, IN0, IN1) mux (K, IN0, IN1 ..) limit (MN, IN, MX) min max (IN1, IN2 ..; OUT), andw orw xorw (IN1, IN2; OUT) ' +
    'invw (IN) shl shr rol ror (IN, N; OUT), concat len left right mid find smove, call (inst = FC / instance DB; its ' +
    'parameters as pins). FBD: boxes whose output feeds no box are the roots, drawn from the top. CFC: "x", "y" (grid 10 px) ' +
    'and "order" (the data flow decides first); without x / y the blocks are placed by the data flow.' + LineEnding +
    'Not available: the S7-1200 has no STL and no S5 timers / counters; the 300/400 have no SInt / USInt / UInt / ' +
    'UDInt and no optimized DBs.';
end;

procedure TClaudeAgent.Ask(const Text: string);
begin
  Ask(Text, nil);
end;

function AttachmentLabel(const A: TChatAttachment): string;
const
  KindNames: array[TChatKindOfFile] of string = ('image', 'PDF', 'text');
begin
  if A.Bytes >= 1024 * 1024 then Result := Format('%s (%s, %.1f MB)', [A.Name, KindNames[A.Kind], A.Bytes / 1048576])
  else Result := Format('%s (%s, %d KB)', [A.Name, KindNames[A.Kind], (A.Bytes + 1023) div 1024]);
end;

{ the content block of an attachment: images and documents go before the text of the question }
function AttachmentBlock(const A: TChatAttachment): TJSONObject;
begin
  case A.Kind of
    cfImage:
      Result := TJSONObject.Create(['type', 'image', 'source',
        TJSONObject.Create(['type', 'base64', 'media_type', A.Media, 'data', A.Data])]);
    cfPdf:
      Result := TJSONObject.Create(['type', 'document', 'title', A.Name, 'source',
        TJSONObject.Create(['type', 'base64', 'media_type', 'application/pdf', 'data', A.Data])]);
  else
    Result := TJSONObject.Create(['type', 'document', 'title', A.Name, 'source',
      TJSONObject.Create(['type', 'text', 'media_type', 'text/plain', 'data', A.Data])]);
  end;
end;

procedure TClaudeAgent.Ask(const Text: string; const Files: TChatAttachments);
var
  M, Last: TJSONObject;
  Content: TJSONArray;
  S, Fs: string;
  K: Integer;
begin
  if Busy or ((Trim(Text) = '') and (Length(Files) = 0)) then Exit;
  AddChat(ckUser, Text);
  Fs := '';
  for K := 0 to High(Files) do Fs := Fs + IfThen(Fs <> '', LineEnding, '') + AttachmentLabel(Files[K]);
  Chat[High(Chat)].Files := Fs;
  FSnapTaken := False;
  FSnap := '';
  FLoops := 0;
  S := Text;
  if Trim(S) = '' then S := 'Look at the attached file(s).';
  if Context <> '' then S := '[' + Context + ']' + LineEnding + LineEnding + S;
  // roles alternate: a conversation that ended on tool results takes the text into that message
  Last := nil;
  if FMessages.Count > 0 then Last := FMessages.Objects[FMessages.Count - 1];
  if (Last <> nil) and (Last.Get('role', '') = 'user') then
  begin
    Content := Last.Arrays['content'];
    for K := 0 to High(Files) do Content.Add(AttachmentBlock(Files[K]));
    Content.Add(TJSONObject.Create(['type', 'text', 'text', S]));
  end
  else
  begin
    Content := TJSONArray.Create;
    for K := 0 to High(Files) do Content.Add(AttachmentBlock(Files[K]));
    Content.Add(TJSONObject.Create(['type', 'text', 'text', S]));
    M := TJSONObject.Create(['role', 'user']);
    M.Add('content', Content);
    FMessages.Add(M);
  end;
  Send;
end;

procedure TClaudeAgent.Send;
var
  Body, Sys: TJSONObject;
  SysArr: TJSONArray;
  Key, Src, Headers: string;
begin
  Key := ClaudeApiKey(Src);
  if Key = '' then
  begin
    AddChat(ckError, 'No API key: Program editor, AI menu, Set ANTHROPIC_API_KEY.');
    State := asIdle;
    Exit;
  end;
  Inc(FLoops);
  Body := TJSONObject.Create;
  try
    Body.Add('model', ClaudeModel);
    Body.Add('max_tokens', 16000);
    SysArr := TJSONArray.Create;
    Sys := TJSONObject.Create(['type', 'text', 'text', SystemPrompt]);
    SysArr.Add(Sys);
    Body.Add('system', SysArr);
    Body.Add('tools', ToolsJson);
    Body.Add('messages', FMessages.Clone);
    // code work: high effort (the model default is medium); adaptive thinking is on by default
    Body.Add('output_config', TJSONObject.Create(['effort', 'high']));
    // a classifier decline is retried on Anthropic's recommended fallback model
    Body.Add('fallbacks', 'default');
    // the system prompt, the tools and the conversation so far are cached
    Body.Add('cache_control', TJSONObject.Create(['type', 'ephemeral']));
    Headers := 'Content-Type: application/json'#13#10 +
      'x-api-key: ' + Key + #13#10 +
      'anthropic-version: 2023-06-01'#13#10 +
      'anthropic-beta: server-side-fallback-2026-07-01';
    FReq := TClaudeRequest.Create(ClaudeBaseUrl + '/v1/messages', Body.AsJSON, Headers);
    FSent := Now;
    State := asWaiting;
  finally
    Body.Free;
  end;
end;

procedure TClaudeAgent.Poll;
var
  R: TClaudeRequest;
  Msg: string;
  J: TJSONData;
begin
  // a read_values waiting for its wait_ms
  if (State = asWaiting) and (FReq = nil) and (FDelayUntil > 0) then
  begin
    if Now < FDelayUntil then Exit;
    FDelayUntil := 0;
    FDelayDone := True;
    WorkTools;
    Exit;
  end;
  if (State <> asWaiting) or (FReq = nil) or not FReq.Done then Exit;
  R := FReq;
  FReq := nil;
  R.WaitFor;
  try
    if R.Cancelled then Exit;
    if R.Status = 0 then
    begin
      AddChat(ckError, 'Claude could not be reached: ' + R.Error);
      State := asIdle;
      Exit;
    end;
    if R.Status <> 200 then
    begin
      Msg := Format('HTTP %d', [R.Status]);
      try
        J := GetJSON(R.Response);
        try
          if (J is TJSONObject) and (TJSONObject(J).Find('error') is TJSONObject) then
            Msg := Msg + ': ' + TJSONObject(J).Objects['error'].Get('message', '');
        finally
          J.Free;
        end;
      except
        Msg := Msg + ': ' + Copy(R.Response, 1, 300);
      end;
      if R.Status = 401 then Msg := Msg + LineEnding + 'The API key was not accepted.';
      AddChat(ckError, Msg);
      // the failed request added nothing: the conversation stays as it was
      State := asIdle;
      Exit;
    end;
    TakeAnswer(R.Response);
  finally
    R.Free;
  end;
end;

procedure TClaudeAgent.TakeAnswer(const S: string);
var
  J: TJSONData;
  Resp, Blk, M, Usage: TJSONObject;
  Content: TJSONArray;
  I: Integer;
  Stop: string;
begin
  try
    J := GetJSON(S);
  except
    on E: Exception do
    begin
      AddChat(ckError, 'The answer was no JSON: ' + E.Message);
      State := asIdle;
      Exit;
    end;
  end;
  try
    if not (J is TJSONObject) or not (TJSONObject(J).Find('content') is TJSONArray) then
    begin
      AddChat(ckError, 'Unexpected answer: ' + Copy(S, 1, 300));
      State := asIdle;
      Exit;
    end;
    Resp := TJSONObject(J);
    if Resp.Find('usage') is TJSONObject then
    begin
      Usage := Resp.Objects['usage'];
      Inc(InTokens, Usage.Get('input_tokens', 0) + Usage.Get('cache_read_input_tokens', 0) +
        Usage.Get('cache_creation_input_tokens', 0));
      Inc(OutTokens, Usage.Get('output_tokens', 0));
    end;
    Content := Resp.Arrays['content'];
    Stop := Resp.Get('stop_reason', '');
    // the answer goes back unchanged (thinking blocks included): the conversation stays append only
    M := TJSONObject.Create(['role', 'assistant']);
    M.Add('content', Content.Clone);
    FMessages.Add(M);
    FreeAndNil(FPending);
    FPending := TJSONArray.Create;
    for I := 0 to Content.Count - 1 do
      if Content.Items[I] is TJSONObject then
      begin
        Blk := Content.Objects[I];
        if Blk.Get('type', '') = 'text' then
        begin
          if Trim(Blk.Get('text', '')) <> '' then AddChat(ckAssistant, Blk.Get('text', ''));
        end
        else if Blk.Get('type', '') = 'tool_use' then
          FPending.Add(Blk.Clone);
      end;
    if Stop = 'refusal' then
    begin
      AddChat(ckError, 'Claude declined this request' + IfThen(Resp.Find('stop_details') is TJSONObject,
        ' (' + Resp.Objects['stop_details'].Get('category', '') + ')', '') + '.');
      FreeAndNil(FPending);
      State := asIdle;
      Exit;
    end;
    if (Stop = 'max_tokens') and (FPending.Count > 0) then
    begin
      // a cut-off tool call is not run; the results say so, so the conversation stays valid
      AddChat(ckError, 'The answer was cut off (max_tokens): its tool calls were not run.');
      FResults.Free;
      FResults := TJSONArray.Create;
      for I := 0 to FPending.Count - 1 do
      begin
        Blk := TJSONObject.Create(['type', 'tool_result', 'tool_use_id', FPending.Objects[I].Get('id', ''),
          'content', 'not run: the answer was cut off at max_tokens', 'is_error', True]);
        FResults.Add(Blk);
      end;
      M := TJSONObject.Create(['role', 'user']);
      M.Add('content', FResults);
      FResults := nil;
      FMessages.Add(M);
      FreeAndNil(FPending);
      State := asIdle;
      Exit;
    end;
    if (Stop <> 'tool_use') or (FPending.Count = 0) then
    begin
      FreeAndNil(FPending);
      State := asIdle;
      Exit;
    end;
    FreeAndNil(FResults);
    FResults := TJSONArray.Create;
    FPendIx := 0;
    WorkTools;
  finally
    J.Free;
  end;
end;

{ the pending tool calls, one after the other; download_and_run waits for the user }
procedure TClaudeAgent.WorkTools;
var
  Blk: TJSONObject;
  Inp: TJSONObject;
  Name, Res: string;
  IsErr: Boolean;
begin
  while FPendIx < FPending.Count do
  begin
    Blk := FPending.Objects[FPendIx];
    Name := Blk.Get('name', '');
    if Name = 'download_and_run' then
    begin
      ConfirmText := 'Claude wants to download the program and switch the CPU to RUN.';
      State := asConfirm;
      Exit;
    end;
    if Blk.Find('input') is TJSONObject then Inp := Blk.Objects['input'] else Inp := nil;
    // read_values with wait_ms: wait first, without blocking the UI (Poll goes on later)
    if (Name = 'read_values') and (Inp <> nil) and (Inp.Get('wait_ms', 0) > 0) and not FDelayDone then
    begin
      FDelayUntil := Now + Min(10000, Inp.Get('wait_ms', 0)) / 86400000;
      State := asWaiting;
      Exit;
    end;
    FDelayDone := False;
    try
      Res := RunTool(Name, Inp, IsErr);
    except
      on E: Exception do
      begin
        Res := 'error: ' + E.Message;
        IsErr := True;
      end;
    end;
    FResults.Add(TJSONObject.Create(['type', 'tool_result', 'tool_use_id', Blk.Get('id', ''), 'content', Res,
      'is_error', IsErr]));
    Inc(FPendIx);
  end;
  FinishTools;
end;

procedure TClaudeAgent.FinishTools;
var
  M: TJSONObject;
begin
  // all the results in one user message
  M := TJSONObject.Create(['role', 'user']);
  M.Add('content', FResults);
  FResults := nil;
  FMessages.Add(M);
  FreeAndNil(FPending);
  if FLoops >= MaxToolLoops then
  begin
    AddChat(ckInfo, Format('Stopped after %d steps: ask again to let Claude go on.', [FLoops]));
    State := asIdle;
    Exit;
  end;
  Send;
end;

procedure TClaudeAgent.Confirm(Allow: Boolean);
var
  Blk: TJSONObject;
  P: TCProgram;
  Res: string;
  IsErr: Boolean;
begin
  if State <> asConfirm then Exit;
  Blk := FPending.Objects[FPendIx];
  IsErr := False;
  if not Allow then
  begin
    Res := 'The user did not allow the download. Ask them to download (F8) when they are ready.';
    AddChat(ckTool, 'download_and_run: not allowed');
  end
  else
  begin
    P := Compile(Project);
    try
      if P.ErrorCount > 0 then
      begin
        Res := 'Not downloaded: ' + CompileJson(nil).AsJSON;
        IsErr := True;
        AddChat(ckTool, Format('download_and_run: %d compile errors', [P.ErrorCount]));
      end
      else
      begin
        if Assigned(OnDownload) then OnDownload;
        Rt.CmdRun;
        Rt.WaitCommands;
        Res := 'Downloaded and switched to RUN. Use read_values to watch the program.';
        AddChat(ckTool, 'download_and_run: downloaded, RUN');
      end;
    finally
      P.Free;
    end;
  end;
  FResults.Add(TJSONObject.Create(['type', 'tool_result', 'tool_use_id', Blk.Get('id', ''), 'content', Res,
    'is_error', IsErr]));
  Inc(FPendIx);
  State := asWaiting;   // not idle while the rest runs
  WorkTools;
end;

procedure TClaudeAgent.Cancel;
var
  M: TJSONObject;
  I: Integer;
begin
  if FReq <> nil then
  begin
    // the thread finishes on its own; its answer is dropped, the conversation stays as it was
    FReq.Cancelled := True;
    FReq.FreeOnTerminate := True;
    if FReq.Done then FReq.Free;
    FReq := nil;
    // the last message is the user's: take it out, so the next request is valid
    if (FMessages.Count > 0) and (FMessages.Objects[FMessages.Count - 1].Get('role', '') = 'user') and
      (FLoops <= 1) then
      FMessages.Delete(FMessages.Count - 1);
    AddChat(ckInfo, 'Stopped.');
  end;
  if State = asConfirm then
  begin
    // pending tool calls get an answer, so the conversation stays valid
    for I := FPendIx to FPending.Count - 1 do
      FResults.Add(TJSONObject.Create(['type', 'tool_result', 'tool_use_id', FPending.Objects[I].Get('id', ''),
        'content', 'stopped by the user', 'is_error', True]));
    M := TJSONObject.Create(['role', 'user']);
    M.Add('content', FResults);
    FResults := nil;
    FMessages.Add(M);
    FreeAndNil(FPending);
  end;
  State := asIdle;
end;

procedure TClaudeAgent.NewChat;
begin
  Cancel;
  FMessages.Clear;
  SetLength(Chat, 0);
  FSnapTaken := False;
  FSnap := '';
end;

function TClaudeAgent.Busy: Boolean;
begin
  Result := State <> asIdle;
end;

function TClaudeAgent.WaitSeconds: Double;
begin
  Result := SecondSpan(Now, FSent);
end;

{ ---------- the project before Claude's first change in a request ---------- }

procedure TClaudeAgent.Snapshot;
var
  F, OldName: string;
  OldMod: Boolean;
  SL: TStringList;
begin
  if FSnapTaken then Exit;
  F := GetTempDir + Format('vplc_claude_%d.vplc', [GetProcessID]);
  OldName := Project.FileName;
  OldMod := Project.Modified;
  Project.SaveToFile(F);
  Project.FileName := OldName;
  Project.Modified := OldMod;
  SL := TStringList.Create;
  try
    SL.LoadFromFile(F);
    FSnap := SL.Text;
  finally
    SL.Free;
  end;
  DeleteFile(F);
  FSnapTaken := True;
end;

function TClaudeAgent.CanUndo: Boolean;
begin
  Result := FSnapTaken and (FSnap <> '') and not Busy;
end;

procedure TClaudeAgent.UndoChanges;
var
  F, OldName: string;
  SL: TStringList;
begin
  if not CanUndo then Exit;
  F := GetTempDir + Format('vplc_claude_%d.vplc', [GetProcessID]);
  SL := TStringList.Create;
  try
    SL.Text := FSnap;
    SL.SaveToFile(F);
  finally
    SL.Free;
  end;
  OldName := Project.FileName;
  Project.LoadFromFile(F);
  Project.FileName := OldName;
  Project.Modified := True;
  DeleteFile(F);
  FSnapTaken := False;
  FSnap := '';
  AddChat(ckInfo, 'Claude''s changes of the last request were undone.');
  if Assigned(OnReloaded) then OnReloaded;
  // Claude learns it on the next request
  Context := Context + IfThen(Context <> '', '; ', '') + 'the user undid your last changes';
end;

{ ---------- the tools ---------- }

function TClaudeAgent.FindBlockRef(const S: string): TBlock;
var
  T: string;
  I, N: Integer;
begin
  Result := nil;
  T := StringReplace(Trim(S), '"', '', [rfReplaceAll]);
  for I := 0 to Project.BlockCount - 1 do
    if SameText(Project.Block(I).Title, T) or SameText(Project.Block(I).Name, T) then Exit(Project.Block(I));
  if (Length(T) > 2) and TryStrToInt(Copy(T, 3, MaxInt), N) then
    for I := 0 to Project.BlockCount - 1 do
      if SameText(Copy(Project.Block(I).Title, 1, 2), Copy(T, 1, 2)) and (Project.Block(I).Number = N) then
        Exit(Project.Block(I));
end;

function NetLang(N: TNetwork): string;
begin
  Result := NetLangName(N.Kind);
end;

function CellJson(const Ce: TLadCell; R, C: Integer): TJSONObject;
var
  P: TJSONArray;
  K: Integer;
  Args: TStringList;
begin
  Result := TJSONObject.Create(['r', R, 'c', C, 'e', LadKindIds[Ce.Kind]]);
  if Ce.Opnd <> '' then Result.Add('op', Ce.Opnd);
  if LadParamCount(Ce.Kind) > 0 then
  begin
    P := TJSONArray.Create;
    for K := 0 to LadParamCount(Ce.Kind) - 1 do P.Add(Ce.P[K]);
    Result.Add('p', P);
  end;
  if (Ce.Kind = lkCall) and (Ce.Args <> '') then
  begin
    Args := TStringList.Create;
    try
      Args.StrictDelimiter := True;
      Args.Delimiter := '|';
      Args.DelimitedText := Ce.Args;
      P := TJSONArray.Create;
      for K := 0 to Args.Count - 1 do P.Add(Args[K]);
      Result.Add('args', P);
    finally
      Args.Free;
    end;
  end;
  if Ce.Down then Result.Add('down', True);
  if LadHasType(Ce.Kind) then Result.Add('type', DataTypeNames[Ce.DType]);
  if LadHasType2(Ce.Kind) then Result.Add('type2', DataTypeNames[Ce.DType2]);
  if Ce.Kind = lkCmp then Result.Add('cmp', CmpOpNames[Ce.Cmp]);
end;

function IfaceJson(B: TBlock): TJSONArray;
var
  K: Integer;
  V: TDbVar;
begin
  Result := TJSONArray.Create;
  for K := 0 to High(B.Iface.Vars) do
  begin
    V := B.Iface.Vars[K];
    Result.Add(TJSONObject.Create(['section', SectionNames[V.Section], 'name', V.Name, 'type', V.TypeText,
      'default', V.Start, 'comment', V.Comment]));
  end;
end;

function TClaudeAgent.BlockJson(B: TBlock): TJSONObject;
var
  I, R, C: Integer;
  N: TNetwork;
  JN: TJSONObject;
  Cells: TJSONArray;
  Nets: TJSONArray;
  Sl, Er: TStringList;
  LN: TIntArray;
begin
  Result := TJSONObject.Create(['block', B.Title, 'name', B.Name, 'comment', B.Comment]);
  Result.Add('interface', IfaceJson(B));
  Nets := TJSONArray.Create;
  for I := 0 to B.NetCount - 1 do
  begin
    N := B.Net(I);
    JN := TJSONObject.Create(['network', I + 1, 'language', NetLang(N), 'title', N.Title, 'comment', N.Comment]);
    if N.Kind in [nkFBD, nkCFC] then
    begin
      // the boxes, and the SCL they compile to (to read them easily)
      NodesToJson(N, JN);
      Sl := TStringList.Create;
      Er := TStringList.Create;
      try
        FbdToScl(N, Project, Sl, LN, Er, B, I + 1);
        JN.Add('as_scl', Sl.Text);
      finally
        Sl.Free;
        Er.Free;
      end;
    end
    else if N.Kind in [nkSTL, nkSCL] then
      JN.Add('code', N.Stl.Text)
    else
    begin
      JN.Add('rows', N.Rows);
      JN.Add('cols', N.Cols);
      Cells := TJSONArray.Create;
      for R := 0 to N.Rows - 1 do
        for C := 0 to N.Cols - 1 do
          if (N.Cell(R, C).Kind <> lkEmpty) or N.Cell(R, C).Down then Cells.Add(CellJson(N.Cell(R, C), R, C));
      JN.Add('cells', Cells);
    end;
    Nets.Add(JN);
  end;
  Result.Add('networks', Nets);
end;

function TClaudeAgent.CompileJson(OnlyBlock: TBlock): TJSONObject;
var
  P: TCProgram;
  K, Ne, Nw: Integer;
  A: TJSONArray;
begin
  P := Compile(Project);
  try
    A := TJSONArray.Create;
    Ne := 0;
    Nw := 0;
    for K := 0 to High(P.Msgs) do
    begin
      if (OnlyBlock <> nil) and not SameText(P.Msgs[K].Block, OnlyBlock.Title) then Continue;
      if P.Msgs[K].IsError then Inc(Ne) else Inc(Nw);
      if A.Count < 40 then
        A.Add(TJSONObject.Create(['block', P.Msgs[K].Block, 'network', P.Msgs[K].Net, 'line', P.Msgs[K].Line,
          'error', P.Msgs[K].IsError, 'text', P.Msgs[K].Text]));
    end;
    Result := TJSONObject.Create(['errors', Ne, 'warnings', Nw]);
    if OnlyBlock <> nil then Result.Add('block', OnlyBlock.Title);
    Result.Add('messages', A);
    if Assigned(OnCompiled) then OnCompiled(P);
  finally
    P.Free;
  end;
end;

function SecByName(const S: string; out Sec: TVarSection): Boolean;
var
  Sc: TVarSection;
begin
  for Sc := Low(TVarSection) to High(TVarSection) do
    if SameText(S, SectionNames[Sc]) then
    begin
      Sec := Sc;
      Exit(True);
    end;
  Result := False;
end;

{ the interface entries of create_block / set_interface }
procedure SetIface(B: TBlock; A: TJSONArray);
var
  K: Integer;
  O: TJSONObject;
  Sec: TVarSection;
begin
  SetLength(B.Iface.Vars, 0);
  if A = nil then Exit;
  for K := 0 to A.Count - 1 do
  begin
    O := A.Objects[K];
    if not SecByName(O.Get('section', ''), Sec) then raise Exception.Create('unknown section ' + O.Get('section', ''));
    if (B.Kind = bkFC) and (Sec = vsStatic) then raise Exception.Create('an FC has no Static (no instance)');
    if (B.Kind = bkFB) and (Sec = vsReturn) then raise Exception.Create('an FB has no Return value');
    if (B.Kind = bkOB) and (Sec <> vsTemp) then raise Exception.Create('an OB has only Temp');
    B.Iface.AddSecVar(Sec, O.Get('name', ''), O.Get('type', 'Int'), O.Get('default', ''), O.Get('comment', ''));
  end;
end;

function TClaudeAgent.RunTool(const Name: string; Inp: TJSONObject; out IsErr: Boolean): string;
var
  B: TBlock;
  N: TNetwork;
  NI, K, R, C, MaxR, MaxC, Num: Integer;
  Res, O: TJSONObject;
  A, Cells: TJSONArray;
  Lang, S, Desc: string;
  Ce: TLadCell;
  Lk, Kk: TLadKind;
  Cm: TCmpOp;
  T: TDataType;
  Lo, Hi: Integer;
  D: TDataBlock;
  Res2: TResolver;
  Opd: TOperand;
  V: LongWord;
  Diag: TDiagArray;
  Changed: Boolean;

  function Need(const Key: string): string;
  begin
    if (Inp = nil) or (Inp.Find(Key) = nil) then raise Exception.Create('missing ' + Key);
    Result := Inp.Get(Key, '');
  end;

  function BlockArg: TBlock;
  begin
    Result := FindBlockRef(Need('block'));
    if Result = nil then raise Exception.Create('no block ' + Inp.Get('block', ''));
  end;

begin
  IsErr := False;
  Changed := False;
  Desc := Name;
  Result := '';
  case Name of
    'get_project':
      begin
        Res := TJSONObject.Create(['cpu', Project.Model.Name, 'family', FamilyNames[Project.Family]]);
        try
          A := TJSONArray.Create;
          for K := 0 to Project.BlockCount - 1 do
          begin
            B := Project.Block(K);
            O := TJSONObject.Create(['block', B.Title, 'name', B.Name, 'comment', B.Comment, 'networks', B.NetCount]);
            S := '';
            for NI := 0 to B.NetCount - 1 do S := S + IfThen(S <> '', ',', '') + NetLang(B.Net(NI));
            O.Add('languages', S);
            if Length(B.Iface.Vars) > 0 then O.Add('interface', IfaceJson(B));
            A.Add(O);
          end;
          Res.Add('blocks', A);
          A := TJSONArray.Create;
          for K := 0 to Project.DBCount - 1 do
          begin
            D := Project.DB(K);
            O := TJSONObject.Create(['db', Format('DB%d', [D.Number]), 'name', D.Name, 'optimized', D.Optimized]);
            if D.InstanceOf > 0 then O.Add('instance_of', Format('FB%d', [D.InstanceOf]))
            else
            begin
              Cells := TJSONArray.Create;
              for R := 0 to High(D.Vars) do
                Cells.Add(TJSONObject.Create(['name', D.Vars[R].Name, 'type', D.Vars[R].TypeText, 'start', D.Vars[R].Start,
                  'comment', D.Vars[R].Comment]));
              O.Add('variables', Cells);
            end;
            A.Add(O);
          end;
          Res.Add('dbs', A);
          A := TJSONArray.Create;
          for K := 0 to Project.UdtCount - 1 do
          begin
            D := Project.Udt(K);
            O := TJSONObject.Create(['type', Project.UdtTypeName(D), 'name', D.Name]);
            Cells := TJSONArray.Create;
            for R := 0 to High(D.Vars) do
              Cells.Add(TJSONObject.Create(['name', D.Vars[R].Name, 'type', D.Vars[R].TypeText]));
            O.Add('members', Cells);
            A.Add(O);
          end;
          Res.Add('plc_data_types', A);
          A := TJSONArray.Create;
          for K := 0 to High(Project.Tags) do
            A.Add(TJSONObject.Create(['name', Project.Tags[K].Name, 'type', Project.Tags[K].TypeText,
              'address', Project.Tags[K].Address, 'comment', Project.Tags[K].Comment]));
          Res.Add('tags', A);
          Res.Add('compile', CompileJson(nil));
          Result := Res.AsJSON;
        finally
          Res.Free;
        end;
      end;
    'get_block':
      begin
        B := BlockArg;
        Desc := 'get_block ' + B.Title;
        Res := BlockJson(B);
        try
          Result := Res.AsJSON;
        finally
          Res.Free;
        end;
      end;
    'write_network':
      begin
        B := BlockArg;
        Lang := UpperCase(Need('language'));
        if (Lang = 'STL') and (Project.Family = cfS71200) then raise Exception.Create('the S7-1200 has no STL: use SCL or LAD');
        if (Lang <> 'STL') and (Lang <> 'SCL') and (Lang <> 'LAD') and (Lang <> 'FBD') and (Lang <> 'CFC') then
          raise Exception.Create('language must be SCL, STL, LAD, FBD or CFC');
        NI := Inp.Get('network', 0);
        if (NI < 0) or (NI > B.NetCount) then raise Exception.Create(Format('%s has networks 1..%d (0 appends)', [B.Title, B.NetCount]));
        // build the network first: a bad cell changes nothing
        if Lang = 'SCL' then N := TNetwork.Create(nkSCL)
        else if Lang = 'STL' then N := TNetwork.Create(nkSTL)
        else if Lang = 'FBD' then N := TNetwork.Create(nkFBD)
        else if Lang = 'CFC' then N := TNetwork.Create(nkCFC)
        else N := TNetwork.Create(nkLAD);
        try
          if N.Kind in [nkFBD, nkCFC] then
          begin
            if not (Inp.Find('nodes') is TJSONArray) then raise Exception.Create(Lang + ' needs nodes (the boxes)');
            NodesFromJson(N, Inp);
            S := FbdNormalize(N, Project);
            if S <> '' then raise Exception.Create(S);
          end
          else if N.Kind in [nkSTL, nkSCL] then
            N.Stl.Text := StringReplace(Need('code'), #13#10, #10, [rfReplaceAll])
          else
          begin
            if not (Inp.Find('cells') is TJSONArray) then raise Exception.Create('LAD needs cells');
            Cells := Inp.Arrays['cells'];
            MaxR := 0;
            MaxC := 0;
            for K := 0 to Cells.Count - 1 do
            begin
              O := Cells.Objects[K];
              R := O.Get('r', -1);
              C := O.Get('c', -1);
              if (R < 0) or (R >= MaxLadRows) or (C < 0) or (C >= MaxLadCols) then
                raise Exception.Create(Format('cell %d: r 0..%d, c 0..%d', [K, MaxLadRows - 1, MaxLadCols - 1]));
              MaxR := Max(MaxR, R);
              MaxC := Max(MaxC, C);
            end;
            N.SetRows(MaxR + 1);
            N.SetCols(Max(LadCols, MaxC + 2));   // one free column on the right
            for K := 0 to Cells.Count - 1 do
            begin
              O := Cells.Objects[K];
              S := LowerCase(O.Get('e', ''));
              Lk := lkEmpty;
              for Kk := Low(TLadKind) to High(TLadKind) do
                if LadKindIds[Kk] = S then Lk := Kk;
              if (Lk = lkEmpty) and (S <> '') and (S <> 'empty') then raise Exception.Create('unknown LAD element "' + S + '"');
              Ce := NewCell(Lk, O.Get('op', ''));
              if O.Find('p') is TJSONArray then
                for R := 0 to Min(4, O.Arrays['p'].Count - 1) do Ce.P[R] := O.Arrays['p'].Strings[R];
              if O.Find('args') is TJSONArray then
              begin
                S := '';
                for R := 0 to O.Arrays['args'].Count - 1 do
                begin
                  if R > 0 then S := S + '|';
                  S := S + O.Arrays['args'].Strings[R];
                end;
                Ce.Args := S;
              end;
              Ce.Down := O.Get('down', False);
              if O.Find('type') <> nil then
              begin
                if not ParseDataType(O.Get('type', 'Int'), T, Lo, Hi) then raise Exception.Create('unknown type ' + O.Get('type', ''));
                Ce.DType := T;
              end;
              if O.Find('type2') <> nil then
              begin
                if not ParseDataType(O.Get('type2', 'Real'), T, Lo, Hi) then raise Exception.Create('unknown type ' + O.Get('type2', ''));
                Ce.DType2 := T;
              end;
              if O.Find('cmp') <> nil then
              begin
                S := O.Get('cmp', '==');
                if S = '=' then S := '==';
                for Cm := Low(TCmpOp) to High(TCmpOp) do
                  if CmpOpNames[Cm] = S then Ce.Cmp := Cm;
              end;
              N.SetCell(O.Get('r', 0), O.Get('c', 0), Ce);
            end;
          end;
          Snapshot;
          if NI = 0 then
          begin
            B.Networks.Add(N);
            NI := B.NetCount;
          end
          else
          begin
            N.Title := B.Net(NI - 1).Title;
            N.Comment := B.Net(NI - 1).Comment;
            B.Net(NI - 1).Free;
            B.Networks[NI - 1] := N;
          end;
          if Inp.Find('title') <> nil then N.Title := Inp.Get('title', '');
          if Inp.Find('comment') <> nil then N.Comment := Inp.Get('comment', '');
          N := nil;
        finally
          N.Free;
        end;
        Changed := True;
        Desc := Format('write_network %s #%d (%s)', [B.Title, NI, Lang]);
        Res := TJSONObject.Create(['written', Format('%s network %d', [B.Title, NI])]);
        try
          Res.Add('compile', CompileJson(B));
          Result := Res.AsJSON;
        finally
          Res.Free;
        end;
      end;
    'delete_network':
      begin
        B := BlockArg;
        NI := Inp.Get('network', 0);
        if (NI < 1) or (NI > B.NetCount) then raise Exception.Create(Format('%s has networks 1..%d', [B.Title, B.NetCount]));
        Snapshot;
        B.DeleteNet(NI - 1);
        Changed := True;
        Desc := Format('delete_network %s #%d', [B.Title, NI]);
        Result := Format('deleted %s network %d; the networks after it moved up one', [B.Title, NI]);
      end;
    'create_block':
      begin
        S := UpperCase(Need('kind'));
        if (S <> 'FB') and (S <> 'FC') then raise Exception.Create('kind must be FC or FB');
        if FindBlockRef(Need('name')) <> nil then raise Exception.Create('a block "' + Inp.Get('name', '') + '" exists already');
        Num := Inp.Get('number', 0);
        if Num <= 0 then
        begin
          Num := 1;
          if S = 'FB' then
            while Project.FindBlock(bkFB, Num) <> nil do Inc(Num)
          else
            while Project.FindBlock(bkFC, Num) <> nil do Inc(Num);
        end
        else if ((S = 'FB') and (Project.FindBlock(bkFB, Num) <> nil)) or ((S = 'FC') and (Project.FindBlock(bkFC, Num) <> nil)) then
          raise Exception.Create(Format('%s%d exists already', [S, Num]));
        Snapshot;
        if S = 'FB' then B := Project.AddBlock(bkFB, Num, Inp.Get('name', ''))
        else B := Project.AddBlock(bkFC, Num, Inp.Get('name', ''));
        B.Comment := Inp.Get('comment', '');
        if Inp.Find('interface') is TJSONArray then SetIface(B, Inp.Arrays['interface']);
        Result := Format('created %s "%s"', [B.Title, B.Name]);
        if (S = 'FB') and (Inp.Get('instance_db', '') <> '') then
        begin
          Num := 1;
          while Project.FindDB(Num) <> nil do Inc(Num);
          D := Project.AddDB(Num, Inp.Get('instance_db', ''));
          D.InstanceOf := B.Number;
          D.Optimized := IsTia(Project.Family);
          D.Layout;
          Result := Result + Format(' and its instance DB%d "%s"', [Num, D.Name]);
        end;
        Changed := True;
        Desc := 'create_block ' + B.Title + ' "' + B.Name + '"';
      end;
    'set_interface':
      begin
        B := BlockArg;
        if not (Inp.Find('interface') is TJSONArray) then raise Exception.Create('missing interface');
        Snapshot;
        SetIface(B, Inp.Arrays['interface']);
        Changed := True;
        Desc := 'set_interface ' + B.Title;
        Res := TJSONObject.Create(['interface', Format('%s: %d entries', [B.Title, Length(B.Iface.Vars)])]);
        try
          Res.Add('compile', CompileJson(B));
          Result := Res.AsJSON;
        finally
          Res.Free;
        end;
      end;
    'add_db_variables':
      begin
        S := StringReplace(Need('db'), '"', '', [rfReplaceAll]);
        D := Project.FindDBByName(S);
        if (D <> nil) and (D.InstanceOf > 0) then raise Exception.Create(S + ' is an instance DB: change its FB interface');
        if not (Inp.Find('variables') is TJSONArray) then raise Exception.Create('missing variables');
        Snapshot;
        if D = nil then
        begin
          Num := Inp.Get('number', 0);
          if (Num <= 0) or (Project.FindDB(Num) <> nil) then
          begin
            Num := 1;
            while Project.FindDB(Num) <> nil do Inc(Num);
          end;
          D := Project.AddDB(Num, S);
          D.Optimized := IsTia(Project.Family);
        end;
        A := Inp.Arrays['variables'];
        for K := 0 to A.Count - 1 do
        begin
          O := A.Objects[K];
          R := D.FindVar(O.Get('name', ''));
          if R >= 0 then
          begin
            D.Vars[R].TypeText := O.Get('type', D.Vars[R].TypeText);
            D.Vars[R].Start := O.Get('start', D.Vars[R].Start);
            if O.Find('comment') <> nil then D.Vars[R].Comment := O.Get('comment', '');
          end
          else
            D.AddVar(O.Get('name', ''), O.Get('type', 'Int'), O.Get('start', ''), O.Get('comment', ''));
        end;
        D.Layout;
        Changed := True;
        Desc := Format('add_db_variables DB%d "%s" (%d)', [D.Number, D.Name, A.Count]);
        Result := Format('DB%d "%s" has %d variables, %d bytes', [D.Number, D.Name, Length(D.Vars), D.Size]);
      end;
    'add_tags':
      begin
        if not (Inp.Find('tags') is TJSONArray) then raise Exception.Create('missing tags');
        A := Inp.Arrays['tags'];
        Snapshot;
        for K := 0 to A.Count - 1 do
        begin
          O := A.Objects[K];
          S := StringReplace(O.Get('name', ''), '"', '', [rfReplaceAll]);
          R := Project.FindTag(S);
          if R >= 0 then
          begin
            Project.Tags[R].TypeText := O.Get('type', Project.Tags[R].TypeText);
            Project.Tags[R].Address := O.Get('address', Project.Tags[R].Address);
            if O.Find('comment') <> nil then Project.Tags[R].Comment := O.Get('comment', '');
          end
          else
            Project.AddTag(S, O.Get('type', 'Bool'), O.Get('address', ''), O.Get('comment', ''));
        end;
        Changed := True;
        Desc := Format('add_tags (%d)', [A.Count]);
        Result := Format('%d tags in the table', [Length(Project.Tags)]);
      end;
    'compile':
      begin
        Res := CompileJson(nil);
        try
          Desc := Format('compile: %d errors, %d warnings', [Res.Get('errors', 0), Res.Get('warnings', 0)]);
          Result := Res.AsJSON;
        finally
          Res.Free;
        end;
      end;
    'read_values':
      begin
        if (Inp = nil) or not (Inp.Find('operands') is TJSONArray) then raise Exception.Create('missing operands');
        A := Inp.Arrays['operands'];
        Res := TJSONObject.Create(['cpu_mode', Copy(GetEnumName(TypeInfo(TRunMode), Ord(Rt.Mode)), 3, 20)]);
        Res2 := TResolver.Create(Project);
        try
          if Rt.Prog = nil then Res.Add('note', 'no program downloaded');
          if Assigned(IsDirty) and IsDirty() then
            Res.Add('note', 'the offline program has changes that are not downloaded: values come from the old program');
          O := TJSONObject.Create;
          for K := 0 to A.Count - 1 do
          begin
            S := A.Strings[K];
            if not Res2.Resolve(S, Opd, Lang, False) or (Opd.Kind <> okAddr) then
              O.Add(S, 'error: ' + IfThen(Lang <> '', Lang, 'not an address'))
            else if not Rt.PeekRaw(Opd, V) then
              O.Add(S, 'not readable now')
            else
              O.Add(S, FormatRaw(V, Opd.A.Size, DefaultFmt(Opd)));
          end;
          Res.Add('values', O);
          Desc := Format('read_values (%d)', [A.Count]);
          Result := Res.AsJSON;
        finally
          Res2.Free;
          Res.Free;
        end;
      end;
    'set_inputs':
      begin
        if (Inp = nil) or not (Inp.Find('inputs') is TJSONObject) then raise Exception.Create('missing inputs');
        O := Inp.Objects['inputs'];
        Res2 := TResolver.Create(Project);
        Res := TJSONObject.Create;
        try
          for K := 0 to O.Count - 1 do
          begin
            S := O.Names[K];
            if not Res2.Resolve(S, Opd, Lang, False) or (Opd.Kind <> okAddr) or not (Opd.A.Area in [arI, arPI]) then
            begin
              Res.Add(S, 'error: not an input ' + Lang);
              IsErr := True;
              Continue;
            end;
            if Opd.A.Size = osBit then
            begin
              Rt.SetSimBit(Opd.A.Ofs, Opd.A.Bit, O.Items[K].AsBoolean);
              Res.Add(S, BoolToStr(O.Items[K].AsBoolean, 'TRUE', 'FALSE'));
            end
            else if Opd.A.Size = osWord then
            begin
              // an analog channel: its generator to manual with this value (the panel writes it every frame)
              R := (Opd.A.Ofs - Project.Model.AIWord) div 2;
              if (R >= 0) and (R <= High(Project.AIch)) and ((Opd.A.Ofs - Project.Model.AIWord) mod 2 = 0) then
              begin
                Project.AIch[R].AiMode := amManual;
                Project.AIch[R].AiValue := EnsureRange(O.Items[K].AsInteger, -32768, 32767);
              end;
              Rt.SetSimWord(Opd.A.Ofs, EnsureRange(O.Items[K].AsInteger, -32768, 32767));
              Res.Add(S, O.Items[K].AsInteger);
            end
            else
            begin
              Res.Add(S, 'error: bits and words only');
              IsErr := True;
            end;
          end;
          Desc := 'set_inputs ' + Copy(Res.AsJSON, 1, 80);
          Result := Res.AsJSON;
        finally
          Res2.Free;
          Res.Free;
        end;
      end;
    'get_diagnostics':
      begin
        Res := TJSONObject.Create(['cpu_mode', Copy(GetEnumName(TypeInfo(TRunMode), Ord(Rt.Mode)), 3, 20),
          'stop_cause', Rt.StopCause, 'cycle', Int64(Rt.CycleNo)]);
        try
          Diag := Rt.DiagCopy(15);
          A := TJSONArray.Create;
          for K := 0 to High(Diag) do A.Add(FormatDateTime('hh:nn:ss.zzz', Diag[K].Time) + '  ' + Diag[K].Text);
          Res.Add('diagnostic_buffer', A);
          Result := Res.AsJSON;
        finally
          Res.Free;
        end;
      end;
  else
    raise Exception.Create('unknown tool ' + Name);
  end;
  AddChat(ckTool, Desc);
  if Changed and Assigned(OnChanged) then OnChanged;
end;

function TClaudeAgent.TestTool(const Name, InputJson: string; out IsErr: Boolean): string;
var
  J: TJSONData;
begin
  J := GetJSON(InputJson);
  try
    try
      Result := RunTool(Name, J as TJSONObject, IsErr);
    except
      on E: Exception do
      begin
        Result := 'error: ' + E.Message;
        IsErr := True;
      end;
    end;
  finally
    J.Free;
  end;
end;

end.
