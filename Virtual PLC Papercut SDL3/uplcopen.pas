unit uPlcOpen;

{ PLCopen XML (IEC 61131-10, TC6 XML 2.01): the exchange format of CODESYS (Project, Export PLCopenXML /
  Import PLCopenXML) and of other IEC 61131-3 tools.

  Export: every block as a POU (OB -> program, FB -> functionBlock, FC -> function) with its interface
  (inputVars, outputVars, inOutVars, localVars, localVars retain, tempVars) and an ST body: SCL networks as they
  are, FBD / CFC as the ST they compile to, LAD as FBD as ST (a network that does not convert, and STL, is left
  out and counted); the PLC data types as dataTypes (struct); the global DBs as globalVars of the resource, the
  tags as a globalVars "IoMap" whose variables carry their address (Start_PB AT %IX0.0); OB1 in the task MainTask.
  The code of a Siemens project is written as CODESYS writes it (CodesysText: no quotes / #, %MW as words).

  Import: the POUs with an ST body (their networks one SCL network), the dataTypes (struct), every globalVars
  of the file (also CODESYS' addData globalvars): a variable with an address becomes a tag, the others a GVL of
  that name. A POU / GVL / type of the same name is replaced. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, StrUtils, Math, DOM, XMLRead, uPlcTypes, uPlcProject, uFbd, uElemHelp, uSclSource;

{ the project as PLCopen XML; Report: what was written, what was left out }
function PlcOpenExport(P: TPlcProject; out Report: string): string;
{ a PLCopen XML file into P; False: not PLCopen XML (Report says why) }
function PlcOpenImport(P: TPlcProject; const Xml: string; out Report: string): Boolean;

implementation

function XmlEsc(const S: string): string;
begin
  Result := StringReplace(S, '&', '&amp;', [rfReplaceAll]);
  Result := StringReplace(Result, '<', '&lt;', [rfReplaceAll]);
  Result := StringReplace(Result, '>', '&gt;', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '&quot;', [rfReplaceAll]);
end;

{ the type element of a type text: <BOOL/>, <string length="20"/>, <array>..</array>, <derived name="TON"/> }
function TypeXml(const T: string): string;
const
  Elem: array[0..23] of string = ('BOOL', 'BYTE', 'WORD', 'DWORD', 'LWORD', 'SINT', 'USINT', 'INT', 'UINT', 'DINT',
    'UDINT', 'LINT', 'ULINT', 'REAL', 'LREAL', 'TIME', 'LTIME', 'DATE', 'TIME_OF_DAY', 'TOD', 'DATE_AND_TIME', 'DT',
    'CHAR', 'WCHAR');
var
  U, E: string;
  Lo, Hi, K: Integer;
begin
  U := UpperCase(Trim(T));
  if (Copy(U, 1, 6) = 'ARRAY[') and SplitArrayType(T, Lo, Hi, E) then
    Exit(Format('<array><dimension lower="%d" upper="%d"/><baseType>%s</baseType></array>', [Lo, Hi, TypeXml(E)]));
  if (U = 'STRING') or (Copy(U, 1, 7) = 'STRING[') then
  begin
    K := StringMaxOf(U);
    if K <= 0 then K := 254;
    Exit(Format('<string length="%d"/>', [K]));
  end;
  if (U = 'WSTRING') or (Copy(U, 1, 8) = 'WSTRING[') then
  begin
    K := StringMaxOf(U);
    if K <= 0 then K := 254;
    Exit(Format('<wstring length="%d"/>', [K]));
  end;
  if U = 'TIME_OF_DAY' then U := 'TOD';
  if U = 'DATE_AND_TIME' then U := 'DT';
  for K := 0 to High(Elem) do
    if U = Elem[K] then Exit('<' + U + '/>');
  // a type of the project: its name without the quotes of TIA ("Motor_T")
  Result := '<derived name="' + XmlEsc(StringReplace(Trim(T), '"', '', [rfReplaceAll])) + '"/>';
end;

function VarXml(const Ind, Name, T, Init, Comment, Address: string): string;
begin
  Result := Ind + '<variable name="' + XmlEsc(Name) + '"';
  if Address <> '' then Result := Result + ' address="' + XmlEsc(Address) + '"';
  Result := Result + '>' + LineEnding + Ind + '  <type>' + TypeXml(T) + '</type>' + LineEnding;
  if Trim(Init) <> '' then
    Result := Result + Ind + '  <initialValue><simpleValue value="' + XmlEsc(Trim(Init)) + '"/></initialValue>' + LineEnding;
  if Trim(Comment) <> '' then
    Result := Result + Ind + '  <documentation><xhtml xmlns="http://www.w3.org/1999/xhtml">' + XmlEsc(Comment) +
      '</xhtml></documentation>' + LineEnding;
  Result := Result + Ind + '</variable>' + LineEnding;
end;

{ "Name : Type := Init; // comment" of a VAR_TEMP line of a network }
procedure ParseDecl(const S: string; out Name, T, Init: string);
var
  L: string;
  P: Integer;
begin
  L := S;
  P := Pos('//', L);
  if P > 0 then L := Copy(L, 1, P - 1);
  L := Trim(StringReplace(L, ';', '', [rfReplaceAll]));
  P := Pos(':=', L);
  if P > 0 then
  begin
    Init := Trim(Copy(L, P + 2, MaxInt));
    L := Trim(Copy(L, 1, P - 1));
  end
  else
    Init := '';
  P := Pos(':', L);
  Name := Trim(Copy(L, 1, P - 1));
  T := Trim(Copy(L, P + 1, MaxInt));
end;

function PlcOpenExport(P: TPlcProject; out Report: string): string;
const
  PouTypes: array[TBlockKind] of string = ('program', 'function', 'functionBlock');
var
  SL, Temps, Consts, Code: TStringList;
  I, J, K, Left, Pous: Integer;
  B: TBlock;
  N, F: TNetwork;
  D: TDataBlock;
  Ret, Nm, Ty, Ini, Er, Body: string;
  Ln: TIntArray;
  Errs: TStringList;
  Cs: Boolean;

  procedure Vars(const Tag: string; Sec: TVarSection; Retain: Integer; Extra: TStrings);
  var
    Q: Integer;
    Head: Boolean;
    V: TDbVar;
  begin
    Head := False;
    for Q := 0 to High(B.Iface.Vars) do
    begin
      V := B.Iface.Vars[Q];
      if V.System or (V.Section <> Sec) then Continue;
      if (Retain >= 0) and (Ord(V.Retain) <> Retain) then Continue;
      if not Head then
        if Retain = 1 then SL.Add('          <' + Tag + ' retain="true">') else SL.Add('          <' + Tag + '>');
      Head := True;
      SL.Add(TrimRight(VarXml('            ', V.Name, V.TypeText, V.Start, V.Comment, '')));
    end;
    if (Extra <> nil) and (Extra.Count > 0) then
    begin
      if not Head then SL.Add('          <' + Tag + '>');
      Head := True;
      for Q := 0 to Extra.Count - 1 do
      begin
        ParseDecl(Extra[Q], Nm, Ty, Ini);
        if (Nm <> '') and (Ty <> '') then SL.Add(TrimRight(VarXml('            ', Nm, Ty, Ini, '', '')));
      end;
    end;
    if Head then SL.Add('          </' + Tag + '>');
  end;

  function Conv(const S: string): string;
  begin
    if Cs then Result := S else Result := CodesysText(S);
  end;

begin
  Report := '';
  Cs := IsCodesys(P.Family);
  SL := TStringList.Create;
  Temps := TStringList.Create;
  Consts := TStringList.Create;
  Code := TStringList.Create;
  Errs := TStringList.Create;
  Left := 0;
  Pous := 0;
  try
    SL.Add('<?xml version="1.0" encoding="utf-8"?>');
    SL.Add('<project xmlns="http://www.plcopen.org/xml/tc6_0201">');
    SL.Add('  <fileHeader companyName="" productName="Virtual PLC" productVersion="1.0" creationDateTime="' +
      FormatDateTime('yyyy-mm-dd"T"hh:nn:ss', Now) + '"/>');
    SL.Add('  <contentHeader name="' + XmlEsc(P.Name) + '">');
    SL.Add('    <coordinateInfo><fbd><scaling x="1" y="1"/></fbd><ld><scaling x="1" y="1"/></ld>' +
      '<sfc><scaling x="1" y="1"/></sfc></coordinateInfo>');
    SL.Add('  </contentHeader>');
    SL.Add('  <types>');
    // the data types: TYPE .. STRUCT
    SL.Add('    <dataTypes>');
    for I := 0 to P.UdtCount - 1 do
    begin
      D := P.Udt(I);
      if D.StrMax > 0 then Continue;
      SL.Add('      <dataType name="' + XmlEsc(D.Name) + '">');
      SL.Add('        <baseType>');
      SL.Add('          <struct>');
      for J := 0 to High(D.Vars) do
        SL.Add(TrimRight(VarXml('            ', D.Vars[J].Name, D.Vars[J].TypeText, D.Vars[J].Start, D.Vars[J].Comment, '')));
      SL.Add('          </struct>');
      SL.Add('        </baseType>');
      SL.Add('      </dataType>');
    end;
    SL.Add('    </dataTypes>');
    // the POUs
    SL.Add('    <pous>');
    for I := 0 to P.BlockCount - 1 do
    begin
      B := P.Block(I);
      Temps.Clear;
      Consts.Clear;
      Code.Clear;
      for J := 0 to B.NetCount - 1 do
      begin
        N := B.Net(J);
        F := nil;
        Er := '';
        case N.Kind of
          nkSCL: F := N;
          nkFBD, nkCFC:
            begin
              F := TNetwork.Create(nkSCL);
              Errs.Clear;
              FbdToScl(N, P, F.Stl, Ln, Errs, B, J + 1);
            end;
          nkLAD:
            begin
              // LAD: as FBD, as ST
              F := LadToFbd(N, P, Er);
              if F <> nil then
              begin
                N := F;
                F := TNetwork.Create(nkSCL);
                Errs.Clear;
                FbdToScl(N, P, F.Stl, Ln, Errs, B, J + 1);
                N.Free;
                N := B.Net(J);
              end;
            end;
        end;
        if F = nil then
        begin
          Inc(Left);
          Code.Add(Format('(* network %d (%s): not exported *)', [J + 1, NetLangName(N.Kind)]));
          Continue;
        end;
        if N.Title <> '' then Code.Add(Format('(* network %d: %s *)', [J + 1, N.Title]))
        else Code.Add(Format('(* network %d *)', [J + 1]));
        SplitNetwork(F, Temps, Consts, Code);
        if F <> N then F.Free;
      end;
      Ret := '';
      for J := 0 to High(B.Iface.Vars) do
        if B.Iface.Vars[J].Section = vsReturn then Ret := B.Iface.Vars[J].TypeText;
      SL.Add('      <pou name="' + XmlEsc(B.Name) + '" pouType="' + PouTypes[B.Kind] + '">');
      SL.Add('        <interface>');
      if B.Kind = bkFC then
        if Ret <> '' then SL.Add('          <returnType>' + TypeXml(Ret) + '</returnType>')
        else SL.Add('          <returnType><derived name="VOID"/></returnType>');
      Vars('inputVars', vsInput, -1, nil);
      Vars('outputVars', vsOutput, -1, nil);
      Vars('inOutVars', vsInOut, -1, nil);
      Vars('localVars', vsStatic, 0, nil);
      Vars('localVars', vsStatic, 1, nil);
      Vars('tempVars', vsTemp, -1, Temps);
      if Consts.Count > 0 then
      begin
        SL.Add('          <localVars constant="true">');
        for J := 0 to Consts.Count - 1 do
        begin
          ParseDecl(Consts[J], Nm, Ty, Ini);
          if (Nm <> '') and (Ty <> '') then SL.Add(TrimRight(VarXml('            ', Nm, Ty, Ini, '', '')));
        end;
        SL.Add('          </localVars>');
      end;
      if B.Comment <> '' then
        SL.Add('          <documentation><xhtml xmlns="http://www.w3.org/1999/xhtml">' + XmlEsc(B.Comment) +
          '</xhtml></documentation>');
      SL.Add('        </interface>');
      Body := '';
      for J := 0 to Code.Count - 1 do Body := Body + Conv(Code[J]) + LineEnding;
      SL.Add('        <body>');
      SL.Add('          <ST><xhtml xmlns="http://www.w3.org/1999/xhtml">' + XmlEsc(TrimRight(Body)) + '</xhtml></ST>');
      SL.Add('        </body>');
      SL.Add('      </pou>');
      Inc(Pous);
    end;
    SL.Add('    </pous>');
    SL.Add('  </types>');
    // the instances: the task with PLC_PRG, the GVLs, the I/O map
    SL.Add('  <instances>');
    SL.Add('    <configurations>');
    SL.Add('      <configuration name="Config">');
    SL.Add('        <resource name="Application">');
    B := P.FindBlock(bkOB, 1);
    SL.Add(Format('          <task name="MainTask" interval="T#%dms" priority="1">', [Max(1, P.CyclicMs div 10)]));
    if B <> nil then SL.Add('            <pouInstance name="' + XmlEsc(B.Name) + '" typeName="' + XmlEsc(B.Name) + '"/>');
    SL.Add('          </task>');
    for I := 0 to P.DBCount - 1 do
    begin
      D := P.DB(I);
      if (D.InstanceOf > 0) or (D.ProgramOf > 0) then Continue;
      SL.Add('          <globalVars name="' + XmlEsc(D.Name) + '">');
      for J := 0 to High(D.Vars) do
        SL.Add(TrimRight(VarXml('            ', D.Vars[J].Name, D.Vars[J].TypeText, D.Vars[J].Start, D.Vars[J].Comment, '')));
      SL.Add('          </globalVars>');
    end;
    if Length(P.Tags) > 0 then
    begin
      SL.Add('          <globalVars name="IoMap">');
      for J := 0 to High(P.Tags) do
        SL.Add(TrimRight(VarXml('            ', P.Tags[J].Name, P.Tags[J].TypeText, '', P.Tags[J].Comment,
          Conv(P.Tags[J].Address))));
      SL.Add('          </globalVars>');
    end;
    SL.Add('        </resource>');
    SL.Add('      </configuration>');
    SL.Add('    </configurations>');
    SL.Add('  </instances>');
    SL.Add('</project>');
    Result := SL.Text;
    Report := Format('%d POUs, %d data types, %d GVLs, %d I/O variables', [Pous, P.UdtCount, P.DBCount, Length(P.Tags)]);
    if Left > 0 then Report := Report + Format('; %d networks left out (STL, or LAD that does not convert)', [Left]);
  finally
    SL.Free;
    Temps.Free;
    Consts.Free;
    Code.Free;
    Errs.Free;
  end;
end;

{ ---------- import ---------- }

function Child(N: TDOMNode; const Name: string): TDOMNode;
var
  C: TDOMNode;
begin
  Result := nil;
  if N = nil then Exit;
  C := N.FirstChild;
  while C <> nil do
  begin
    if SameText(C.NodeName, Name) then Exit(C);
    C := C.NextSibling;
  end;
end;

function Attr(N: TDOMNode; const Name: string): string;
begin
  Result := '';
  if (N is TDOMElement) then Result := TDOMElement(N).GetAttribute(Name);
end;

function TextOf(N: TDOMNode): string;
begin
  if N = nil then Result := '' else Result := N.TextContent;
end;

{ the type text of a <type> / <baseType> element }
function TypeText(N: TDOMNode): string;
var
  C, Dm: TDOMNode;
begin
  Result := '';
  if N = nil then Exit;
  C := N.FirstChild;
  while (C <> nil) and not (C is TDOMElement) do C := C.NextSibling;
  if C = nil then Exit;
  if SameText(C.NodeName, 'derived') then Exit(Attr(C, 'name'));
  if SameText(C.NodeName, 'string') or SameText(C.NodeName, 'wstring') then
  begin
    Result := UpperCase(C.NodeName);
    if Attr(C, 'length') <> '' then Result := Result + '[' + Attr(C, 'length') + ']';
    Exit;
  end;
  if SameText(C.NodeName, 'array') then
  begin
    Dm := Child(C, 'dimension');
    Exit(Format('Array[%s..%s] of %s', [Attr(Dm, 'lower'), Attr(Dm, 'upper'), TypeText(Child(C, 'baseType'))]));
  end;
  Result := UpperCase(C.NodeName);
  if Result = 'TOD' then Result := 'TIME_OF_DAY';
  if Result = 'DT' then Result := 'DATE_AND_TIME';
end;

function InitOf(V: TDOMNode): string;
begin
  Result := Attr(Child(Child(V, 'initialValue'), 'simpleValue'), 'value');
end;

function DocOf(V: TDOMNode): string;
begin
  Result := Trim(TextOf(Child(V, 'documentation')));
end;

procedure FindAll(N: TDOMNode; const Name: string; L: TList);
var
  C: TDOMNode;
begin
  C := N.FirstChild;
  while C <> nil do
  begin
    if SameText(C.NodeName, Name) then L.Add(C) else FindAll(C, Name, L);
    C := C.NextSibling;
  end;
end;

function PlcOpenImport(P: TPlcProject; const Xml: string; out Report: string): Boolean;
var
  Doc: TXMLDocument;
  St: TStringStream;
  L: TList;
  I, K, Num, NPou, NGvl, NTag, NType, NSkip: Integer;
  Pou, Itf, Sec, V, Body: TDOMNode;
  B: TBlock;
  Bk: TBlockKind;
  D: TDataBlock;
  Nm, Pt, Code: string;
  S: TVarSection;
begin
  Result := False;
  Report := '';
  NPou := 0;
  NGvl := 0;
  NTag := 0;
  NType := 0;
  NSkip := 0;
  St := TStringStream.Create(Xml);
  L := TList.Create;
  try
    try
      ReadXMLFile(Doc, St);
    except
      on E: Exception do
      begin
        Report := 'not XML: ' + E.Message;
        Exit;
      end;
    end;
    try
      if not SameText(Doc.DocumentElement.NodeName, 'project') then
      begin
        Report := 'not PLCopen XML (no <project>)';
        Exit;
      end;
      // the data types
      FindAll(Doc.DocumentElement, 'dataType', L);
      for I := 0 to L.Count - 1 do
      begin
        Pou := TDOMNode(L[I]);
        Sec := Child(Child(Pou, 'baseType'), 'struct');
        if Sec = nil then Continue;
        Nm := Attr(Pou, 'name');
        D := P.FindUdt(Nm);
        if D = nil then
        begin
          Num := 1;
          while P.FindUdt('UDT' + IntToStr(Num)) <> nil do Inc(Num);
          D := P.AddUdt(Num, Nm);
        end;
        D.Vars := nil;
        V := Sec.FirstChild;
        while V <> nil do
        begin
          if SameText(V.NodeName, 'variable') then
            D.AddVar(Attr(V, 'name'), TypeText(Child(V, 'type')), InitOf(V), DocOf(V));
          V := V.NextSibling;
        end;
        Inc(NType);
      end;
      // the POUs with an ST body
      L.Clear;
      FindAll(Doc.DocumentElement, 'pou', L);
      for I := 0 to L.Count - 1 do
      begin
        Pou := TDOMNode(L[I]);
        Nm := Attr(Pou, 'name');
        Pt := Attr(Pou, 'pouType');
        Body := Child(Child(Pou, 'body'), 'ST');
        if Body = nil then
        begin
          Inc(NSkip);
          Continue;
        end;
        if SameText(Pt, 'program') then Bk := bkOB
        else if SameText(Pt, 'functionBlock') then Bk := bkFB
        else Bk := bkFC;
        B := nil;
        for K := 0 to P.BlockCount - 1 do
          if (P.Block(K).Kind = Bk) and SameText(P.Block(K).Name, Nm) then B := P.Block(K);
        if B <> nil then
        begin
          Num := B.Number;
          P.DeleteBlock(P.Blocks.IndexOf(B));
        end
        else
        begin
          // OB1 for the first program, then the next free numbers
          Num := 1;
          if Bk = bkOB then
            while P.FindBlock(bkOB, Num) <> nil do Inc(Num)
          else
            while P.FindBlock(Bk, Num) <> nil do Inc(Num);
        end;
        B := P.AddBlock(Bk, Num, Nm);
        Itf := Child(Pou, 'interface');
        if Itf <> nil then
        begin
          Sec := Itf.FirstChild;
          while Sec <> nil do
          begin
            S := vsTemp;
            if SameText(Sec.NodeName, 'inputVars') then S := vsInput
            else if SameText(Sec.NodeName, 'outputVars') then S := vsOutput
            else if SameText(Sec.NodeName, 'inOutVars') then S := vsInOut
            else if SameText(Sec.NodeName, 'localVars') then S := vsStatic
            else if SameText(Sec.NodeName, 'tempVars') then S := vsTemp
            else if SameText(Sec.NodeName, 'returnType') then
            begin
              if not SameText(TypeText(Sec), 'VOID') then B.Iface.AddSecVar(vsReturn, 'Ret_Val', TypeText(Sec), '', '');
              Sec := Sec.NextSibling;
              Continue;
            end
            else if SameText(Sec.NodeName, 'documentation') then
            begin
              B.Comment := Trim(TextOf(Sec));
              Sec := Sec.NextSibling;
              Continue;
            end
            else
            begin
              Sec := Sec.NextSibling;
              Continue;
            end;
            // a FUNCTION has no VAR that keeps its value: its locals are temps
            if (Bk = bkFC) and (S = vsStatic) then S := vsTemp;
            V := Sec.FirstChild;
            while V <> nil do
            begin
              if SameText(V.NodeName, 'variable') then
              begin
                K := B.Iface.AddSecVar(S, Attr(V, 'name'), TypeText(Child(V, 'type')), InitOf(V), DocOf(V));
                if (K >= 0) and SameText(Attr(Sec, 'retain'), 'true') then B.Iface.Vars[K].Retain := True;
              end;
              V := V.NextSibling;
            end;
            Sec := Sec.NextSibling;
          end;
        end;
        if Bk = bkOB then P.SyncObIface(B) else B.Iface.SortSections;
        Code := TextOf(Body);
        with B.AddNet(nkSCL) do
        begin
          Title := Nm;
          Stl.Text := Code;
        end;
        Inc(NPou);
      end;
      // the global variables: a variable with an address is a tag, the others are in a GVL of their list's name
      L.Clear;
      FindAll(Doc.DocumentElement, 'globalVars', L);
      for I := 0 to L.Count - 1 do
      begin
        Sec := TDOMNode(L[I]);
        Nm := Attr(Sec, 'name');
        if Nm = '' then Nm := 'GVL';
        D := nil;
        V := Sec.FirstChild;
        while V <> nil do
        begin
          if SameText(V.NodeName, 'variable') then
            if Attr(V, 'address') <> '' then
            begin
              K := P.FindTag(Attr(V, 'name'));
              if K >= 0 then
              begin
                P.Tags[K].Address := Attr(V, 'address');
                P.Tags[K].TypeText := TypeText(Child(V, 'type'));
              end
              else
                P.AddTag(Attr(V, 'name'), TypeText(Child(V, 'type')), Attr(V, 'address'), DocOf(V));
              Inc(NTag);
            end
            else
            begin
              if D = nil then
              begin
                D := P.FindDBByName(Nm);
                if D = nil then
                begin
                  Num := 1;
                  while P.FindDB(Num) <> nil do Inc(Num);
                  D := P.AddDB(Num, Nm);
                  D.Optimized := True;
                  Inc(NGvl);
                end;
              end;
              K := D.FindVar(Attr(V, 'name'));
              if K >= 0 then D.DeleteVar(K);
              D.AddVar(Attr(V, 'name'), TypeText(Child(V, 'type')), InitOf(V), DocOf(V));
            end;
          V := V.NextSibling;
        end;
      end;
      Report := Format('imported: %d POUs, %d data types, %d new GVLs, %d I/O variables', [NPou, NType, NGvl, NTag]);
      if NSkip > 0 then Report := Report + Format('; %d POUs without an ST body left out (LD / FBD / SFC)', [NSkip]);
      P.Modified := True;
      Result := True;
    finally
      Doc.Free;
    end;
  finally
    St.Free;
    L.Free;
  end;
end;

end.
