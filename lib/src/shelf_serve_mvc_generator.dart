// Copyright 2019 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'dart:async' show Future;

import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:build/build.dart';
import 'package:code_builder/code_builder.dart';
import 'package:source_gen/source_gen.dart';
import 'package:shelf_serve_mvc/shelf_serve_mvc.dart';

extension ReaderFieldBuilder on BlockBuilder {}

extension DartTypeExtension on DartType {
  bool get isDartBasicType {
    return isDartCoreNum || isDartCoreString || isDartCoreBool || isDartCoreList || isDartCoreMap || isDartCoreSet || isDartCoreDouble || isDartCoreInt;
  }
}

class ShelfServeMvcGenerator extends Generator {
  static bool _checkParameterElement(ParameterElement element) {
    if (element.type.isDartCoreType) {
      return true;
    }
    if (element.type.element?.kind != ElementKind.CLASS) {
      return false;
    }
    ClassElement cls = element.type.element as ClassElement;
    if (cls.constructors.any((e) => e.isFactory && e.name == 'fromRequest')) {
      return true;
    }
    return false;
  }

  static Code _routerCodeFromAnnotation(DartObject obj, MethodElement method) {
    return refer("router").property("add").call(
      [
        literalString(obj.getField("method")?.toStringValue() ?? obj.getField('(super)')?.getField("method")?.toStringValue() ?? ""),
        literalString(obj.getField("path")?.toStringValue() ?? obj.getField('(super)')?.getField("path")?.toStringValue() ?? ""),
        CodeExpression(
          Code(
            "(request) => _${method.name}(request)",
          ),
        ),
      ],
    ).statement;
  }

  static Expression _readFieldExpression(DartType fieldType, {String? fieldName, bool isRequired = false}) {
    return refer("await _fieldParser").property("parseField").call(
      [],
      {
        if (fieldName != null) "field": refer("\"$fieldName\""),
        "isRequired": isRequired ? literalTrue : literalFalse,
      },
      [refer(fieldType.element!.name!)],
    );
  }

  @override
  Future<String?> generate(LibraryReader library, BuildStep buildStep) async {
    List<Spec> mixins = [];
    for (final cls in library.classes) {
      if (cls.methods.any(TypeChecker.fromRuntime(HttpMethod).hasAnnotationOf) == false) {
        continue;
      }
      List<Method> methods = [];
      List<Code> routerCodes = [];
      for (var method in cls.methods) {
        final annotations = TypeChecker.fromRuntime(HttpMethod).annotationsOf(method);
        assert(() {
          if (method.parameters.isEmpty) {
            return true;
          }
          if (method.type.optionalParameterNames.isNotEmpty) {
            return false;
          }
          return method.parameters.every((element) => _checkParameterElement(element));
        }());
        if (annotations.isEmpty) {
          continue;
        }
        routerCodes.addAll(annotations.map((e) => _routerCodeFromAnnotation(e, method)));
        methods.add(
          Method(
            (b) => b
              ..name = "_${method.name}"
              ..modifier = MethodModifier.async
              ..requiredParameters.add(
                Parameter(
                  (b) => b
                    ..name = 'request'
                    ..type = refer('Request'),
                ),
              )
              ..returns = refer('Future<Response>')
              ..body = Block(
                (b) {
                  for (var i = 0; i < method.type.normalParameterNames.length; i++) {
                    DartType parameterType = method.type.normalParameterTypes[i];
                    if (!parameterType.isDartBasicType) {
                      b.addExpression(
                        refer("_fieldParser").property("modelParsers").index(refer(parameterType.element!.name!)).assign(
                              refer("MvcFactoryRequestModelParser<${parameterType.element!.name!}>").newInstance(
                                [
                                  refer("(data) => ${parameterType.element!.name!}.fromRequestField(data)"),
                                ],
                              ),
                            ),
                      );
                    }
                    b.addExpression(
                      declareFinal('p$i').assign(
                        _readFieldExpression(
                          method.type.normalParameterTypes[i],
                          fieldName: method.parameters.length > 1 ? method.type.normalParameterNames[i] : null,
                          isRequired: method.type.normalParameterTypes[i].nullabilitySuffix == NullabilitySuffix.none,
                        ),
                      ),
                    );
                    b.statements.add(
                      Code("""
                      if(p$i.error != null){
                        return Response(400, body:p$i.error!);
                      }"""),
                    );
                  }
                  for (var element in method.type.namedParameterTypes.entries) {
                    if (!element.value.isDartBasicType) {
                      b.addExpression(
                        refer("_fieldParser").property("modelParsers").index(refer(element.value.element!.name!)).assign(
                              refer("MvcFactoryRequestModelParser<${element.value.element!.name!}>").newInstance(
                                [
                                  refer("(data) => ${element.value.element!.name!}.fromRequestField(data)"),
                                ],
                              ),
                            ),
                      );
                    }
                    b.addExpression(
                      declareFinal("namedP${element.key}").assign(
                        _readFieldExpression(
                          element.value,
                          fieldName: element.key,
                          isRequired: method.parameters.firstWhere((e) => e.name == element.key).isRequired,
                        ),
                      ),
                    );
                    b.statements.add(
                      Code("""
                        if(namedP${element.key}.error != null){
                          return Response(400, body: namedP${element.key}.error);
                        }"""),
                    );
                  }
                  b.addExpression(
                    refer("(this as ${cls.name})").property(method.name).call(
                      List.generate(
                        method.type.normalParameterNames.length,
                        (e) => refer(
                          "p$e.value${method.type.normalParameterTypes[e].nullabilitySuffix == NullabilitySuffix.none ? "!" : ""}",
                        ),
                      ),
                      method.type.namedParameterTypes.map(
                        (key, value) {
                          return MapEntry(
                            key,
                            refer(
                              "namedP$key.value${value.nullabilitySuffix == NullabilitySuffix.none ? (method.parameters.firstWhere((e) => e.name == key).defaultValueCode != null ? "?? ${method.parameters.firstWhere((e) => e.name == key).defaultValueCode}" : "!") : ""}",
                            ),
                          );
                        },
                      ),
                    ).returned,
                  );
                },
              ),
          ),
        );
      }
      final mixin = Mixin(
        (builder) {
          builder.name = "_\$${cls.name}";
          builder.on = refer("MvcController");
          builder.fields.add(
            Field(
              (b) {
                b.modifier = FieldModifier.final$;
                b.type = refer("MvcRequestFieldParser");
                b.name = "_fieldParser";
                b.late = true;
                b.assignment = refer("getService").call(
                  [],
                  {},
                  [refer("MvcRequestFieldParser")],
                ).code;
              },
            ),
          );

          builder.methods.add(
            Method(
              (b) => b
                ..name = 'call'
                ..annotations.add(refer('override'))
                ..requiredParameters.add(
                  Parameter(
                    (b) => b
                      ..name = 'request'
                      ..type = refer('Request'),
                  ),
                )
                ..returns = refer('Future<Response>')
                ..body = Block(
                  (b) => b
                    ..addExpression(declareFinal('router').assign(refer('Router').newInstance([])))
                    ..statements.addAll(routerCodes)
                    ..addExpression(refer('router').property("call").call([refer("request")]).returned),
                ),
            ),
          );

          builder.methods.addAll(methods);
        },
      );
      mixins.add(mixin);
    }
    return Library((b) => b.body.addAll(mixins)).accept(DartEmitter(useNullSafetySyntax: true)).toString();
  }
}
