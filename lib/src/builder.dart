import 'package:build/build.dart';
import 'package:source_gen/source_gen.dart';

import 'shelf_serve_mvc_generator.dart';

Builder shelfServeMvc(BuilderOptions _) => SharedPartBuilder(
      [ShelfServeMvcGenerator()],
      'shelf_serve_mvc',
    );
