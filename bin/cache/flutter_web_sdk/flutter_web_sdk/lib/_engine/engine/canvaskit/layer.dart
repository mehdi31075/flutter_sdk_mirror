// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// @dart = 2.12
part of dart._engine;

/// A layer to be composed into a scene.
///
/// A layer is the lowest-level rendering primitive. It represents an atomic
/// painting command.
abstract class Layer implements ui.EngineLayer {
  /// The layer that contains us as a child.
  ContainerLayer? parent;

  /// An estimated rectangle that this layer will draw into.
  ui.Rect paintBounds = ui.Rect.zero;

  /// Whether or not this layer actually needs to be painted in the scene.
  bool get needsPainting => !paintBounds.isEmpty;

  /// Pre-process this layer before painting.
  ///
  /// In this step, we compute the estimated [paintBounds] as well as
  /// apply heuristics to prepare the render cache for pictures that
  /// should be cached.
  void preroll(PrerollContext prerollContext, Matrix4 matrix);

  /// Paint this layer into the scene.
  void paint(PaintContext paintContext);
}

/// A context shared by all layers during the preroll pass.
class PrerollContext {
  /// A raster cache. Used to register candidates for caching.
  final RasterCache? rasterCache;

  /// A compositor for embedded HTML views.
  final HtmlViewEmbedder? viewEmbedder;

  final MutatorsStack mutatorsStack = MutatorsStack();

  PrerollContext(this.rasterCache, this.viewEmbedder);
}

/// A context shared by all layers during the paint pass.
class PaintContext {
  /// A multi-canvas that applies clips, transforms, and opacity
  /// operations to all canvases (root canvas and overlay canvases for the
  /// platform views).
  CkNWayCanvas internalNodesCanvas;

  /// The canvas for leaf nodes to paint to.
  CkCanvas? leafNodesCanvas;

  /// A raster cache potentially containing pre-rendered pictures.
  final RasterCache? rasterCache;

  /// A compositor for embedded HTML views.
  final HtmlViewEmbedder? viewEmbedder;

  PaintContext(
    this.internalNodesCanvas,
    this.leafNodesCanvas,
    this.rasterCache,
    this.viewEmbedder,
  );
}

/// A layer that contains child layers.
abstract class ContainerLayer extends Layer {
  final List<Layer> _layers = <Layer>[];

  /// The list of child layers.
  ///
  /// Useful in tests.
  List<Layer> get debugLayers => _layers;

  /// Register [child] as a child of this layer.
  void add(Layer child) {
    child.parent = this;
    _layers.add(child);
  }

  @override
  void preroll(PrerollContext prerollContext, Matrix4 matrix) {
    paintBounds = prerollChildren(prerollContext, matrix);
  }

  /// Run [preroll] on all of the child layers.
  ///
  /// Returns a [Rect] that covers the paint bounds of all of the child layers.
  /// If all of the child layers have empty paint bounds, then the returned
  /// [Rect] is empty.
  ui.Rect prerollChildren(PrerollContext context, Matrix4 childMatrix) {
    ui.Rect childPaintBounds = ui.Rect.zero;
    for (Layer layer in _layers) {
      layer.preroll(context, childMatrix);
      if (childPaintBounds.isEmpty) {
        childPaintBounds = layer.paintBounds;
      } else if (!layer.paintBounds.isEmpty) {
        childPaintBounds = childPaintBounds.expandToInclude(layer.paintBounds);
      }
    }
    return childPaintBounds;
  }

  /// Calls [paint] on all child layers that need painting.
  void paintChildren(PaintContext context) {
    assert(needsPainting);

    for (Layer layer in _layers) {
      if (layer.needsPainting) {
        layer.paint(context);
      }
    }
  }
}

class BackdropFilterEngineLayer extends ContainerLayer implements ui.BackdropFilterEngineLayer {
  final ui.ImageFilter _filter;

  BackdropFilterEngineLayer(this._filter);

  @override
  void paint(PaintContext context) {
    context.internalNodesCanvas.saveLayerWithFilter(paintBounds, _filter);
    paintChildren(context);
    context.internalNodesCanvas.restore();
  }
}

/// A layer that clips its child layers by a given [Path].
class ClipPathEngineLayer extends ContainerLayer implements ui.ClipPathEngineLayer {
  /// The path used to clip child layers.
  final CkPath _clipPath;
  final ui.Clip _clipBehavior;

  ClipPathEngineLayer(this._clipPath, this._clipBehavior)
      : assert(_clipBehavior != ui.Clip.none);

  @override
  void preroll(PrerollContext context, Matrix4 matrix) {
    context.mutatorsStack.pushClipPath(_clipPath);
    final ui.Rect childPaintBounds = prerollChildren(context, matrix);
    final ui.Rect clipBounds = _clipPath.getBounds();
    if (childPaintBounds.overlaps(clipBounds)) {
      paintBounds = childPaintBounds.intersect(clipBounds);
    }
    context.mutatorsStack.pop();
  }

  @override
  void paint(PaintContext paintContext) {
    assert(needsPainting);

    paintContext.internalNodesCanvas.save();
    paintContext.internalNodesCanvas
        .clipPath(_clipPath, _clipBehavior != ui.Clip.hardEdge);

    if (_clipBehavior == ui.Clip.antiAliasWithSaveLayer) {
      paintContext.internalNodesCanvas.saveLayer(paintBounds, null);
    }
    paintChildren(paintContext);
    if (_clipBehavior == ui.Clip.antiAliasWithSaveLayer) {
      paintContext.internalNodesCanvas.restore();
    }
    paintContext.internalNodesCanvas.restore();
  }
}

/// A layer that clips its child layers by a given [Rect].
class ClipRectEngineLayer extends ContainerLayer implements ui.ClipRectEngineLayer {
  /// The rectangle used to clip child layers.
  final ui.Rect _clipRect;
  final ui.Clip _clipBehavior;

  ClipRectEngineLayer(this._clipRect, this._clipBehavior)
      : assert(_clipBehavior != ui.Clip.none);

  @override
  void preroll(PrerollContext context, Matrix4 matrix) {
    context.mutatorsStack.pushClipRect(_clipRect);
    final ui.Rect childPaintBounds = prerollChildren(context, matrix);
    if (childPaintBounds.overlaps(_clipRect)) {
      paintBounds = childPaintBounds.intersect(_clipRect);
    }
    context.mutatorsStack.pop();
  }

  @override
  void paint(PaintContext paintContext) {
    assert(needsPainting);

    paintContext.internalNodesCanvas.save();
    paintContext.internalNodesCanvas.clipRect(
      _clipRect,
      ui.ClipOp.intersect,
      _clipBehavior != ui.Clip.hardEdge,
    );
    if (_clipBehavior == ui.Clip.antiAliasWithSaveLayer) {
      paintContext.internalNodesCanvas.saveLayer(_clipRect, null);
    }
    paintChildren(paintContext);
    if (_clipBehavior == ui.Clip.antiAliasWithSaveLayer) {
      paintContext.internalNodesCanvas.restore();
    }
    paintContext.internalNodesCanvas.restore();
  }
}

/// A layer that clips its child layers by a given [RRect].
class ClipRRectEngineLayer extends ContainerLayer implements ui.ClipRRectEngineLayer {
  /// The rounded rectangle used to clip child layers.
  final ui.RRect _clipRRect;
  final ui.Clip? _clipBehavior;

  ClipRRectEngineLayer(this._clipRRect, this._clipBehavior)
      : assert(_clipBehavior != ui.Clip.none);

  @override
  void preroll(PrerollContext context, Matrix4 matrix) {
    context.mutatorsStack.pushClipRRect(_clipRRect);
    final ui.Rect childPaintBounds = prerollChildren(context, matrix);
    if (childPaintBounds.overlaps(_clipRRect.outerRect)) {
      paintBounds = childPaintBounds.intersect(_clipRRect.outerRect);
    }
    context.mutatorsStack.pop();
  }

  @override
  void paint(PaintContext paintContext) {
    assert(needsPainting);

    paintContext.internalNodesCanvas.save();
    paintContext.internalNodesCanvas
        .clipRRect(_clipRRect, _clipBehavior != ui.Clip.hardEdge);
    if (_clipBehavior == ui.Clip.antiAliasWithSaveLayer) {
      paintContext.internalNodesCanvas.saveLayer(paintBounds, null);
    }
    paintChildren(paintContext);
    if (_clipBehavior == ui.Clip.antiAliasWithSaveLayer) {
      paintContext.internalNodesCanvas.restore();
    }
    paintContext.internalNodesCanvas.restore();
  }
}

/// A layer that paints its children with the given opacity.
class OpacityEngineLayer extends ContainerLayer implements ui.OpacityEngineLayer {
  final int _alpha;
  final ui.Offset _offset;

  OpacityEngineLayer(this._alpha, this._offset);

  @override
  void preroll(PrerollContext context, Matrix4 matrix) {
    final Matrix4 childMatrix = Matrix4.copy(matrix);
    childMatrix.translate(_offset.dx, _offset.dy);
    context.mutatorsStack
        .pushTransform(Matrix4.translationValues(_offset.dx, _offset.dy, 0.0));
    context.mutatorsStack.pushOpacity(_alpha);
    super.preroll(context, childMatrix);
    context.mutatorsStack.pop();
    context.mutatorsStack.pop();
    paintBounds = paintBounds.translate(_offset.dx, _offset.dy);
  }

  @override
  void paint(PaintContext paintContext) {
    assert(needsPainting);

    final CkPaint paint = CkPaint();
    paint.color = ui.Color.fromARGB(_alpha, 0, 0, 0);

    paintContext.internalNodesCanvas.save();
    paintContext.internalNodesCanvas.translate(_offset.dx, _offset.dy);

    final ui.Rect saveLayerBounds = paintBounds.shift(-_offset);

    paintContext.internalNodesCanvas.saveLayer(saveLayerBounds, paint);
    paintChildren(paintContext);
    // Restore twice: once for the translate and once for the saveLayer.
    paintContext.internalNodesCanvas.restore();
    paintContext.internalNodesCanvas.restore();
  }
}

/// A layer that transforms its child layers by the given transform matrix.
class TransformEngineLayer extends ContainerLayer implements ui.TransformEngineLayer {
  /// The matrix with which to transform the child layers.
  final Matrix4 _transform;

  TransformEngineLayer(this._transform);

  @override
  void preroll(PrerollContext context, Matrix4 matrix) {
    final Matrix4 childMatrix = matrix * _transform;
    context.mutatorsStack.pushTransform(_transform);
    final ui.Rect childPaintBounds = prerollChildren(context, childMatrix);
    paintBounds = transformRect(_transform, childPaintBounds);
    context.mutatorsStack.pop();
  }

  @override
  void paint(PaintContext paintContext) {
    assert(needsPainting);

    paintContext.internalNodesCanvas.save();
    paintContext.internalNodesCanvas.transform(_transform.storage);
    paintChildren(paintContext);
    paintContext.internalNodesCanvas.restore();
  }
}

/// Translates its children along x and y coordinates.
///
/// This is a thin wrapper over [TransformEngineLayer] just so the framework
/// gets the "OffsetEngineLayer" when calling `runtimeType.toString()`. This is
/// better for debugging.
class OffsetEngineLayer extends TransformEngineLayer implements ui.OffsetEngineLayer {
  OffsetEngineLayer(double dx, double dy) : super(Matrix4.translationValues(dx, dy, 0.0));
}

/// A layer that applies an [ui.ImageFilter] to its children.
class ImageFilterEngineLayer extends ContainerLayer implements ui.ImageFilterEngineLayer {
  ImageFilterEngineLayer(this._filter);

  final ui.ImageFilter _filter;

  @override
  void paint(PaintContext paintContext) {
    assert(needsPainting);
    final CkPaint paint = CkPaint();
    paint.imageFilter = _filter;
    paintContext.internalNodesCanvas.saveLayer(paintBounds, paint);
    paintChildren(paintContext);
    paintContext.internalNodesCanvas.restore();
  }
}

class ShaderMaskEngineLayer extends ContainerLayer implements ui.ShaderMaskEngineLayer {
  @override
  void paint(PaintContext paintContext) {
    // TODO(yjbanov): this needs to be implemented
  }
}

/// A layer containing a [Picture].
class PictureLayer extends Layer {
  /// The picture to paint into the canvas.
  final CkPicture picture;

  /// The offset at which to paint the picture.
  final ui.Offset offset;

  /// A hint to the compositor about whether this picture is complex.
  final bool isComplex;

  /// A hint to the compositor that this picture is likely to change.
  final bool willChange;

  PictureLayer(this.picture, this.offset, this.isComplex, this.willChange);

  @override
  void preroll(PrerollContext prerollContext, Matrix4 matrix) {
    paintBounds = picture.cullRect!.shift(offset);
  }

  @override
  void paint(PaintContext paintContext) {
    assert(picture != null); // ignore: unnecessary_null_comparison
    assert(needsPainting);

    paintContext.leafNodesCanvas!.save();
    paintContext.leafNodesCanvas!.translate(offset.dx, offset.dy);

    paintContext.leafNodesCanvas!.drawPicture(picture);
    paintContext.leafNodesCanvas!.restore();
  }
}

/// A layer representing a physical shape.
///
/// The shape clips its children to a given [Path], and casts a shadow based
/// on the given elevation.
class PhysicalShapeEngineLayer extends ContainerLayer
    implements ui.PhysicalShapeEngineLayer {
  final double _elevation;
  final ui.Color _color;
  final ui.Color? _shadowColor;
  final CkPath _path;
  final ui.Clip _clipBehavior;

  PhysicalShapeEngineLayer(
    this._elevation,
    this._color,
    this._shadowColor,
    this._path,
    this._clipBehavior,
  );

  @override
  void preroll(PrerollContext prerollContext, Matrix4 matrix) {
    prerollChildren(prerollContext, matrix);
    paintBounds = computeSkShadowBounds(_path, _elevation, ui.window.devicePixelRatio, matrix);
  }

  @override
  void paint(PaintContext paintContext) {
    assert(needsPainting);

    if (_elevation != 0) {
      drawShadow(paintContext.leafNodesCanvas!, _path, _shadowColor!,
          _elevation, _color.alpha != 0xff);
    }

    final CkPaint paint = CkPaint()..color = _color;
    if (_clipBehavior != ui.Clip.antiAliasWithSaveLayer) {
      paintContext.leafNodesCanvas!.drawPath(_path, paint);
    }

    final int saveCount = paintContext.internalNodesCanvas.save();
    switch (_clipBehavior) {
      case ui.Clip.hardEdge:
        paintContext.internalNodesCanvas.clipPath(_path, false);
        break;
      case ui.Clip.antiAlias:
        paintContext.internalNodesCanvas.clipPath(_path, true);
        break;
      case ui.Clip.antiAliasWithSaveLayer:
        paintContext.internalNodesCanvas.clipPath(_path, true);
        paintContext.internalNodesCanvas.saveLayer(paintBounds, null);
        break;
      case ui.Clip.none:
        break;
    }

    if (_clipBehavior == ui.Clip.antiAliasWithSaveLayer) {
      // If we want to avoid the bleeding edge artifact
      // (https://github.com/flutter/flutter/issues/18057#issue-328003931)
      // using saveLayer, we have to call drawPaint instead of drawPath as
      // anti-aliased drawPath will always have such artifacts.
      paintContext.leafNodesCanvas!.drawPaint(paint);
    }

    paintChildren(paintContext);

    paintContext.internalNodesCanvas.restoreToCount(saveCount);
  }

  /// Draws a shadow on the given [canvas] for the given [path].
  ///
  /// The blur of the shadow is decided by the [elevation], and the
  /// shadow is painted with the given [color].
  static void drawShadow(CkCanvas canvas, CkPath path, ui.Color color,
      double elevation, bool transparentOccluder) {
    canvas.drawShadow(path, color, elevation, transparentOccluder);
  }
}

/// A layer which contains a [ui.ColorFilter].
class ColorFilterEngineLayer extends ContainerLayer implements ui.ColorFilterEngineLayer {
  ColorFilterEngineLayer(this.filter);

  final ui.ColorFilter filter;

  @override
  void paint(PaintContext paintContext) {
    assert(needsPainting);

    CkPaint paint = CkPaint();
    paint.colorFilter = filter;

    paintContext.internalNodesCanvas.saveLayer(paintBounds, paint);
    paintChildren(paintContext);
    paintContext.internalNodesCanvas.restore();
  }
}

/// A layer which renders a platform view (an HTML element in this case).
class PlatformViewLayer extends Layer {
  PlatformViewLayer(this.viewId, this.offset, this.width, this.height);

  final int viewId;
  final ui.Offset offset;
  final double width;
  final double height;

  @override
  void preroll(PrerollContext context, Matrix4 matrix) {
    paintBounds = ui.Rect.fromLTWH(offset.dx, offset.dy, width, height);
    context.viewEmbedder!.prerollCompositeEmbeddedView(
      viewId,
      EmbeddedViewParams(
        offset,
        ui.Size(width, height),
        context.mutatorsStack,
      ),
    );
  }

  @override
  void paint(PaintContext context) {
    CkCanvas? canvas = context.viewEmbedder!.compositeEmbeddedView(viewId);
    context.leafNodesCanvas = canvas;
  }
}
