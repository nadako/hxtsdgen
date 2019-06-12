package hxtsdgen;

import haxe.io.Path;
import haxe.macro.Compiler;
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Type;
using haxe.macro.Tools;
using StringTools;

import hxtsdgen.DocRenderer.renderDoc;
import hxtsdgen.ArgsRenderer.renderArgs;
import hxtsdgen.TypeRenderer.renderType;

enum ExposeKind {
    EClass(c:ClassType);
    EEnum(c:ClassType);
    ETypedef(t:DefType, anon:AnonType);
    EMethod(c:ClassType, cf:ClassField);
}

class Generator {
    public static inline var GEN_ENUM_TS = #if hxtsdgen_enums_ts true #else false #end;
    static inline var SKIP_HEADER = #if hxtsdgen_skip_header true #else false #end;
    static inline var HEADER = "// Generated by Haxe TypeScript Declaration Generator :)";
    static inline var NO_EXPOSE_HINT = "// No types were @:expose'd.\n// Read more at http://haxe.org/manual/target-javascript-expose.html";

    static function use() {
        if (Context.defined("display") || !Context.defined("js"))
            return;

        Context.onGenerate(function(types) {
            var outJS = Compiler.getOutput();
            var outPath = Path.directory(outJS);
            var outName = Path.withoutDirectory(Path.withoutExtension(outJS));
            var outDTS = Path.join([outPath, outName + ".d.ts"]);
            var outETS = Path.join([outPath, outName + "-enums.ts"]);

            var exposed = [];
            for (type in types) {
                switch [type, type.follow()] {
                    case [TType(_.get() => t, _), TAnonymous(_.get() => anon)]:
                        if (t.meta.has(":expose")) {
                            exposed.push(ETypedef(t, anon));
                        }
                    case [_, TInst(_.get() => cl, _)]:
                        if (cl.meta.has(':enum')) {
                            if (GEN_ENUM_TS || cl.meta.has(":expose"))
                                exposed.push(EEnum(cl));
                        } else {
                            if (cl.meta.has(":expose")) {
                                exposed.push(EClass(cl));
                            }
                            for (f in cl.statics.get()) {
                                if (f.meta.has(":expose"))
                                    exposed.push(EMethod(cl, f));
                            }
                        }
                    default:
                }
            }

            if (exposed.length == 0) {
                var src = NO_EXPOSE_HINT;
                if (!SKIP_HEADER) src = HEADER + "\n\n" + src;
                sys.io.File.saveContent(outDTS, src);
            } else {
                Context.onAfterGenerate(function() {
                    var gen = new Generator();
                    var declarations = gen.generate(exposed, true);
                    gen.dispose();

                    if (GEN_ENUM_TS && declarations.ets.length > 0) {
                        if (!SKIP_HEADER) declarations.ets.unshift(HEADER);
                        sys.io.File.saveContent(outETS, declarations.ets.join("\n\n"));

                        // import enum from the d.ts
                        var exports = declarations.exports.join(', ');
                        declarations.dts.unshift('import { $exports } from "./$outName-enums";');
                    }

                    if (declarations.dts.length > 0) {
                        if (!SKIP_HEADER) declarations.dts.unshift(HEADER);
                        sys.io.File.saveContent(outDTS, declarations.dts.join("\n\n"));
                    }
                });
            }
        });
    }

    static public var ensureIncluded:Type -> Bool;

    var dtsDecl:Array<String>;
    var etsDecl:Array<String>;
    var etsExports:Array<String>;
    var autoIncluded:Map<String, Bool>;

    function new() {
        dtsDecl = [];
        etsDecl = GEN_ENUM_TS ? [] : dtsDecl;
        etsExports = [];
        autoIncluded = new Map<String, Bool>();
        ensureIncluded = _ensureIncluded;
    }

    function dispose() {
        ensureIncluded = null;
    }

    function generate(exposed:Array<ExposeKind>, isExport:Bool) {
        for (e in exposed) {
            switch (e) {
                case EClass(cl):
                    dtsDecl.push(generateClassDeclaration(cl, isExport));
                case EEnum(t):
                    var eDecl = generateEnumDeclaration(t, isExport);
                    if (eDecl != "") etsDecl.push(eDecl);
                case ETypedef(t, anon):
                    dtsDecl.push(generateTypedefDeclaration(t, anon, isExport));
                case EMethod(cl, f):
                    dtsDecl.push(generateFunctionDeclaration(cl, isExport, f));
            }
        }
        return {
            dts: dtsDecl,
            ets: etsDecl,
            exports: etsExports
        };
    }

    function _ensureIncluded(t:Type) {
        // A type is referenced, maybe it needs to be generated as well
        switch [t, t.follow()] {
            case [_, TInst(_.get() => cl, _)] if (!cl.meta.has(":expose") && !cl.meta.has(":native")):
                var key = cl.pack.join('.') + '.' + cl.name;
                if (!autoIncluded.exists(key)) {
                    autoIncluded.set(key, true);
                    generate([EClass(cl)], false); // insert before type processed
                }
                return true;
            case [TType(_.get() => tt, _), TAnonymous(_.get() => anon)]:
                var key = tt.pack.join('.') + '.' + tt.name;
                if (!autoIncluded.exists(key)) {
                    autoIncluded.set(key, true);
                    generate([ETypedef(tt, anon)], false); // insert before type processed
                }
                return true;
            case [TAbstract(_.get() => ab, params), _]:
                var cl = ab.impl.get();
                if (cl.meta.has(':enum')) {
                    var key = cl.pack.join('.') + '.' + cl.name;
                    if (!autoIncluded.exists(key)) {
                        autoIncluded.set(key, true);
                        generate([EEnum(cl)], GEN_ENUM_TS); // insert before type processed
                    }
                    return true;
                }
            default:
        }
        return false;
    }

    static public function getExposePath(m:MetaAccess):Array<String> {
        switch (m.extract(":expose")) {
            case []: return null; // not exposed
            case [{params: []}]: return null;
            case [{params: [macro $v{(s:String)}]}]: return s.split(".");
            case [_]: throw "invalid @:expose argument!"; // probably handled by compiler
            case _: throw "multiple @:expose metadata!"; // is this okay?
        }
    }

    static function wrapInNamespace(exposedPath:Array<String>, fn:String->String->String):String {
        var name = exposedPath.pop();
        return if (exposedPath.length == 0)
            fn(name, "");
        else
            'export namespace ${exposedPath.join(".")} {\n${fn(name, "\t")}\n}';
    }

    function generateFunctionDeclaration(cl:ClassType, isExport:Bool, f:ClassField):String {
        var exposePath = getExposePath(f.meta);
        if (exposePath == null)
            exposePath = cl.pack.concat([cl.name, f.name]);

        return wrapInNamespace(exposePath, function(name, indent) {
            var parts = [];
            if (f.doc != null)
                parts.push(renderDoc(f.doc, indent));

            switch [f.kind, f.type] {
                case [FMethod(_), TFun(args, ret)]:
                    var prefix = isExport ? "export function " : "function ";
                    parts.push(renderFunction(name, args, ret, f.params, indent, prefix));
                default:
                    throw new Error("This kind of field cannot be exposed to JavaScript", f.pos);
            }

            return parts.join("\n");
        });
    }

    function renderFunction(name:String, args:Array<{name:String, opt:Bool, t:Type}>, ret:Type, params:Array<TypeParameter>, indent:String, prefix:String):String {
        var tparams = renderTypeParams(params);
        return '$indent$prefix$name$tparams(${renderArgs(this, args)}): ${renderType(this, ret)};';
    }

    function renderTypeParams(params:Array<TypeParameter>):String {
        return
            if (params.length == 0) ""
            else "<" + params.map(function(t) return return t.name).join(", ") + ">";
    }

    function generateClassDeclaration(cl:ClassType, isExport:Bool):String {
        var exposePath = getExposePath(cl.meta);
        if (exposePath == null)
            exposePath = cl.pack.concat([cl.name]);

        return wrapInNamespace(exposePath, function(name, indent) {
            var parts = [];

            if (cl.doc != null)
                parts.push(renderDoc(cl.doc, indent));

            // TODO: maybe it's a good idea to output all-static class that is not referenced
            // elsewhere as a namespace for TypeScript
            var tparams = renderTypeParams(cl.params);
            var isInterface = cl.isInterface;
            var type = isInterface ? 'interface' : 'class';
            var export = isExport ? "export " : "";
            parts.push('$indent${export}$type $name$tparams {');

            {
                var indent = indent + "\t";
                generateConstructor(cl, isInterface, indent, parts);

                var fields = cl.fields.get();
                for (field in fields)
                    if (field.isPublic || isPropertyGetterSetter(fields, field))
                        addField(field, false, isInterface, indent, parts);

                fields = cl.statics.get();
                for (field in fields)
                    if (field.isPublic || isPropertyGetterSetter(fields, field))
                        addField(field, true, isInterface, indent, parts);
            }

            parts.push('$indent}');
            return parts.join("\n");
        });
    }

    function generateEnumDeclaration(t:ClassType, isExport:Bool):String {
        // TypeScript `const enum` are pure typing constructs (e.g. don't exist in JS either)
        // so it matches Haxe abstract enum well.

        // Unwrap abstract type
        var bt:BaseType = t;
        switch (t.kind) {
            case KAbstractImpl(_.get() => at): bt = at;
            default: // we keep what we have
        }

        var exposePath = getExposePath(t.meta);
        if (exposePath == null)
            exposePath = bt.pack.concat([bt.name]);

        return wrapInNamespace(exposePath, function(name, indent) {
            var parts = [];

            if (t.doc != null)
                parts.push(renderDoc(t.doc, indent));

            var export = isExport ? "export " : (exposePath.length == 0 ? "declare " : "");
            parts.push('$indent${export}const enum $name {');

            {
                var indent = indent + "\t";
                var added = 0;
                var fields = t.statics.get();
                for (field in fields)
                    if (field.isPublic)
                        added += addConstValue(field, indent, parts) ? 1 : 0;
                if (added == 0) return ""; // empty enum
            }

            if (GEN_ENUM_TS && isExport) {
                // this will be imported by the d.ts
                // - no package: enum name
                // - with package: root package (com.foo.Bar -> com)
                if (exposePath.length == 0) etsExports.push(name);
                else {
                    var ns = exposePath[0];
                    if (etsExports.indexOf(ns) < 0) etsExports.push(ns);
                }
            }

            parts.push('$indent}');
            return parts.join("\n");
        });
    }

    function generateTypedefDeclaration(t:DefType, anon:AnonType, isExport:Bool):String {
        var exposePath = getExposePath(t.meta);
        if (exposePath == null)
            exposePath = t.pack.concat([t.name]);

        return wrapInNamespace(exposePath, function(name, indent) {
            var parts = [];

            if (t.doc != null)
                parts.push(renderDoc(t.doc, indent));

            var tparams = renderTypeParams(t.params);
            var export = isExport ? "export " : "";
            parts.push('$indent${export}type $name$tparams = {');

            {
                var indent = indent + "\t";
                var fields = anon.fields;
                for (field in fields)
                    if (field.isPublic)
                        addField(field, false, true, indent, parts);
            }

            parts.push('$indent}');
            return parts.join("\n");
        });
    }

    function addConstValue(field:ClassField, indent:String, parts:Array<String>) {
        switch (field.kind) {
            case FVar(_, _):
                var expr = field.expr().expr;
                var value = switch (expr) {
                    case TCast(_.expr => TConst(c), _):
                        switch (c) {
                            case TInt(v): Std.string(v);
                            case TFloat(f): Std.string(f);
                            case TString(s): '"${escapeString(s)}"';
                            case TNull: null; // not allowed
                            case TBool(_): null; // not allowed
                            default: null;
                        }
                    default: null;
                };
                if (value != null) {
                    parts.push('$indent${field.name} = $value,');
                    return true;
                }
            default:
        }
        return false;
    }

    function escapeString(s:String) {
        return s.split('\\').join('\\\\')
            .split('"').join('\\"');
    }

    function addField(field:ClassField, isStatic:Bool, isInterface:Bool, indent:String, parts:Array<String>) {
        if (field.doc != null)
            parts.push(renderDoc(field.doc, indent));

        var prefix = if (isStatic) "static " else "";

        switch [field.kind, field.type] {
            case [FMethod(_), TFun(args, ret)]:
                parts.push(renderFunction(field.name, args, ret, field.params, indent, prefix));

            case [FVar(read, write), _]:
                switch (write) {
                    case AccNo|AccNever|AccCall:
                        prefix += "readonly ";
                    default:
                }
                if (read != AccCall) {
                    var option = isInterface && isNullable(field) ? "?" : "";
                    parts.push('$indent$prefix${field.name}$option: ${renderType(this, field.type)};');
                }

            default:
        }
    }

    function generateConstructor(cl:ClassType, isInterface:Bool, indent:String, parts:Array<String>) {
        var privateCtor = true;
        if (cl.constructor != null) {
            var ctor = cl.constructor.get();
            privateCtor = false;
            if (ctor.doc != null)
                parts.push(renderDoc(ctor.doc, indent));
            switch (ctor.type) {
                case TFun(args, _):
                    var prefix = if (ctor.isPublic) "" else "private "; // TODO: should this really be protected?
                    parts.push('${indent}${prefix}constructor(${renderArgs(this, args)});');
                default:
                    throw "wtf";
            }
        } else if (!isInterface) {
            parts.push('${indent}private constructor();');
        }
    }

    // For a given `method` looking like a `get_x`/`set_x`, look for a matching property
    function isPropertyGetterSetter(fields:Array<ClassField>, method:ClassField) {
        var re = new EReg('(get|set)_(.*)', '');
        if (re.match(method.name)) {
            var name = re.matched(2);
            for (field in fields) if (field.name == name && isProperty(field)) return true;
        }
        return false;
    }

    function isProperty(field) {
        return switch(field.kind) {
            case FVar(read, write): write == AccCall || read == AccCall;
            default: false;
        };
    }

    function renderGetter(field:ClassField, indent:String, prefix:String) {
        return renderFunction('get_${field.name}', [], field.type, field.params, indent, prefix);
    }

    function renderSetter(field:ClassField, indent:String, prefix:String) {
        var args = [{
            name: 'value',
            opt: false,
            t: field.type
        }];
        return renderFunction('set_${field.name}', args, field.type, field.params, indent, prefix);
    }

    function isNullable(field:ClassField) {
        return switch (field.type) {
            case TType(_.get() => _.name => 'Null', _): true;
            default: false;
        }
    }

}
