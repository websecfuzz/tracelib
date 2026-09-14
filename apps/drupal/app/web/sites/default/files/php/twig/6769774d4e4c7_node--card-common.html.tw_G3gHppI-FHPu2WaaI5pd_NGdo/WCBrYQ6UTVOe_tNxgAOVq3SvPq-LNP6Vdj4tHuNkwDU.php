<?php

use Twig\Environment;
use Twig\Error\LoaderError;
use Twig\Error\RuntimeError;
use Twig\Extension\CoreExtension;
use Twig\Extension\SandboxExtension;
use Twig\Markup;
use Twig\Sandbox\SecurityError;
use Twig\Sandbox\SecurityNotAllowedTagError;
use Twig\Sandbox\SecurityNotAllowedFilterError;
use Twig\Sandbox\SecurityNotAllowedFunctionError;
use Twig\Source;
use Twig\Template;
use Twig\TemplateWrapper;

/* core/profiles/demo_umami/themes/umami/templates/content/node--card-common.html.twig */
class __TwigTemplate_61de7d040d01854b6f0ca8234ee1873d extends Template
{
    private Source $source;
    /**
     * @var array<string, Template>
     */
    private array $macros = [];

    public function __construct(Environment $env)
    {
        parent::__construct($env);

        $this->source = $this->getSourceContext();

        $this->parent = false;

        $this->blocks = [
        ];
        $this->sandbox = $this->extensions[SandboxExtension::class];
        $this->checkSecurity();
    }

    protected function doDisplay(array $context, array $blocks = []): iterable
    {
        $macros = $this->macros;
        // line 63
        $context["classes"] = ["node", ("node--type-" . \Drupal\Component\Utility\Html::getClass(CoreExtension::getAttribute($this->env, $this->source,         // line 65
($context["node"] ?? null), "bundle", [], "any", false, false, true, 65))), ((CoreExtension::getAttribute($this->env, $this->source,         // line 66
($context["node"] ?? null), "isPromoted", [], "method", false, false, true, 66)) ? ("node--promoted") : ("")), ((CoreExtension::getAttribute($this->env, $this->source,         // line 67
($context["node"] ?? null), "isSticky", [], "method", false, false, true, 67)) ? ("node--sticky") : ("")), (( !CoreExtension::getAttribute($this->env, $this->source,         // line 68
($context["node"] ?? null), "isPublished", [], "method", false, false, true, 68)) ? ("node--unpublished") : ("")), ((        // line 69
($context["view_mode"] ?? null)) ? (("node--view-mode-" . \Drupal\Component\Utility\Html::getClass(($context["view_mode"] ?? null)))) : (""))];
        // line 72
        yield $this->extensions['Drupal\Core\Template\TwigExtension']->escapeFilter($this->env, $this->extensions['Drupal\Core\Template\TwigExtension']->attachLibrary("umami/classy.node"), "html", null, true);
        yield "

";
        // line 74
        $context["read_more"] = ('' === $tmp = \Twig\Extension\CoreExtension::captureOutput((function () use (&$context, $macros, $blocks) {
            // line 75
            yield t("View @node.type.entity.label", array("@node.type.entity.label" => CoreExtension::getAttribute($this->env, $this->source, CoreExtension::getAttribute($this->env, $this->source, CoreExtension::getAttribute($this->env, $this->source, ($context["node"] ?? null), "type", [], "any", false, false, true, 75), "entity", [], "any", false, false, true, 75), "label", [], "method", false, false, true, 75), ));
            yield from [];
        })())) ? '' : new Markup($tmp, $this->env->getCharset());
        // line 77
        yield "
";
        // line 78
        yield from $this->loadTemplate("core/profiles/demo_umami/themes/umami/templates/content/node--card-common.html.twig", "core/profiles/demo_umami/themes/umami/templates/content/node--card-common.html.twig", 78, "1084228128")->unwrap()->yield(CoreExtension::toArray(["attributes" => CoreExtension::getAttribute($this->env, $this->source,         // line 79
($context["attributes"] ?? null), "addClass", [($context["classes"] ?? null)], "method", false, false, true, 79), "content" =>         // line 80
($context["content"] ?? null), "content_attributes" =>         // line 81
($context["content_attributes"] ?? null), "label" =>         // line 82
($context["label"] ?? null), "title_attributes" =>         // line 83
($context["title_attributes"] ?? null), "title_prefix" =>         // line 84
($context["title_prefix"] ?? null), "title_suffix" =>         // line 85
($context["title_suffix"] ?? null), "read_more" =>         // line 86
($context["read_more"] ?? null), "url" =>         // line 87
($context["url"] ?? null)]));
        $this->env->getExtension('\Drupal\Core\Template\TwigExtension')
            ->checkDeprecations($context, ["node", "view_mode", "attributes", "content", "content_attributes", "label", "title_attributes", "title_prefix", "title_suffix", "url"]);        yield from [];
    }

    /**
     * @codeCoverageIgnore
     */
    public function getTemplateName(): string
    {
        return "core/profiles/demo_umami/themes/umami/templates/content/node--card-common.html.twig";
    }

    /**
     * @codeCoverageIgnore
     */
    public function isTraitable(): bool
    {
        return false;
    }

    /**
     * @codeCoverageIgnore
     */
    public function getDebugInfo(): array
    {
        return array (  74 => 87,  73 => 86,  72 => 85,  71 => 84,  70 => 83,  69 => 82,  68 => 81,  67 => 80,  66 => 79,  65 => 78,  62 => 77,  58 => 75,  56 => 74,  51 => 72,  49 => 69,  48 => 68,  47 => 67,  46 => 66,  45 => 65,  44 => 63,);
    }

    public function getSourceContext(): Source
    {
        return new Source("", "core/profiles/demo_umami/themes/umami/templates/content/node--card-common.html.twig", "/var/www/html/app/web/core/profiles/demo_umami/themes/umami/templates/content/node--card-common.html.twig");
    }
    
    public function checkSecurity()
    {
        static $tags = array("set" => 63, "trans" => 75, "embed" => 78);
        static $filters = array("clean_class" => 65, "escape" => 72);
        static $functions = array("attach_library" => 72);

        try {
            $this->sandbox->checkSecurity(
                ['set', 'trans', 'embed'],
                ['clean_class', 'escape'],
                ['attach_library'],
                $this->source
            );
        } catch (SecurityError $e) {
            $e->setSourceContext($this->source);

            if ($e instanceof SecurityNotAllowedTagError && isset($tags[$e->getTagName()])) {
                $e->setTemplateLine($tags[$e->getTagName()]);
            } elseif ($e instanceof SecurityNotAllowedFilterError && isset($filters[$e->getFilterName()])) {
                $e->setTemplateLine($filters[$e->getFilterName()]);
            } elseif ($e instanceof SecurityNotAllowedFunctionError && isset($functions[$e->getFunctionName()])) {
                $e->setTemplateLine($functions[$e->getFunctionName()]);
            }

            throw $e;
        }

    }
}


/* core/profiles/demo_umami/themes/umami/templates/content/node--card-common.html.twig */
class __TwigTemplate_61de7d040d01854b6f0ca8234ee1873d___1084228128 extends Template
{
    private Source $source;
    /**
     * @var array<string, Template>
     */
    private array $macros = [];

    public function __construct(Environment $env)
    {
        parent::__construct($env);

        $this->source = $this->getSourceContext();

        $this->blocks = [
            'content' => [$this, 'block_content'],
        ];
        $this->sandbox = $this->extensions[SandboxExtension::class];
        $this->checkSecurity();
    }

    protected function doGetParent(array $context): bool|string|Template|TemplateWrapper
    {
        // line 78
        return "umami:card";
    }

    protected function doDisplay(array $context, array $blocks = []): iterable
    {
        $macros = $this->macros;
        $this->parent = $this->loadTemplate("umami:card", "core/profiles/demo_umami/themes/umami/templates/content/node--card-common.html.twig", 78);
        yield from $this->parent->unwrap()->yield($context, array_merge($this->blocks, $blocks));
        $this->env->getExtension('\Drupal\Core\Template\TwigExtension')
            ->checkDeprecations($context, ["title_attributes", "label", "content", "title_prefix", "title_suffix", "read_more", "url", "content_attributes"]);    }

    // line 89
    /**
     * @return iterable<null|scalar|\Stringable>
     */
    public function block_content(array $context, array $blocks = []): iterable
    {
        $macros = $this->macros;
        // line 90
        yield "    ";
        yield from $this->loadTemplate("core/profiles/demo_umami/themes/umami/templates/content/node--card-common.html.twig", "core/profiles/demo_umami/themes/umami/templates/content/node--card-common.html.twig", 90, "260435806")->unwrap()->yield(CoreExtension::toArray(["attributes" => CoreExtension::getAttribute($this->env, $this->source,         // line 91
($context["title_attributes"] ?? null), "addClass", ["umami-card__title"], "method", false, false, true, 91), "label" => ((        // line 92
($context["label"] ?? null)) ? (($context["label"] ?? null)) : (CoreExtension::getAttribute($this->env, $this->source, ($context["content"] ?? null), "field_title", [], "any", false, false, true, 92))), "title_prefix" =>         // line 93
($context["title_prefix"] ?? null), "title_suffix" =>         // line 94
($context["title_suffix"] ?? null)]));
        // line 103
        yield "    ";
        yield from $this->loadTemplate("core/profiles/demo_umami/themes/umami/templates/content/node--card-common.html.twig", "core/profiles/demo_umami/themes/umami/templates/content/node--card-common.html.twig", 103, "672496136")->unwrap()->yield(CoreExtension::toArray(["attributes" => $this->extensions['Drupal\Core\Template\TwigExtension']->createAttribute(["class" => ["umami-card__read-more"]]), "read_more" =>         // line 105
($context["read_more"] ?? null), "label" =>         // line 106
($context["label"] ?? null), "url" =>         // line 107
($context["url"] ?? null)]));
        // line 116
        yield "    <div";
        yield $this->extensions['Drupal\Core\Template\TwigExtension']->escapeFilter($this->env, CoreExtension::getAttribute($this->env, $this->source, ($context["content_attributes"] ?? null), "addClass", ["umami-card__content"], "method", false, false, true, 116), "html", null, true);
        yield ">
      ";
        // line 117
        yield $this->extensions['Drupal\Core\Template\TwigExtension']->escapeFilter($this->env, ($context["content"] ?? null), "html", null, true);
        yield "
    </div>
  ";
        yield from [];
    }

    /**
     * @codeCoverageIgnore
     */
    public function getTemplateName(): string
    {
        return "core/profiles/demo_umami/themes/umami/templates/content/node--card-common.html.twig";
    }

    /**
     * @codeCoverageIgnore
     */
    public function isTraitable(): bool
    {
        return false;
    }

    /**
     * @codeCoverageIgnore
     */
    public function getDebugInfo(): array
    {
        return array (  201 => 117,  196 => 116,  194 => 107,  193 => 106,  192 => 105,  190 => 103,  188 => 94,  187 => 93,  186 => 92,  185 => 91,  183 => 90,  176 => 89,  164 => 78,  74 => 87,  73 => 86,  72 => 85,  71 => 84,  70 => 83,  69 => 82,  68 => 81,  67 => 80,  66 => 79,  65 => 78,  62 => 77,  58 => 75,  56 => 74,  51 => 72,  49 => 69,  48 => 68,  47 => 67,  46 => 66,  45 => 65,  44 => 63,);
    }

    public function getSourceContext(): Source
    {
        return new Source("", "core/profiles/demo_umami/themes/umami/templates/content/node--card-common.html.twig", "/var/www/html/app/web/core/profiles/demo_umami/themes/umami/templates/content/node--card-common.html.twig");
    }
    
    public function checkSecurity()
    {
        static $tags = array("extends" => 78, "embed" => 90);
        static $filters = array("escape" => 116);
        static $functions = array("create_attribute" => 104);

        try {
            $this->sandbox->checkSecurity(
                ['extends', 'embed'],
                ['escape'],
                ['create_attribute'],
                $this->source
            );
        } catch (SecurityError $e) {
            $e->setSourceContext($this->source);

            if ($e instanceof SecurityNotAllowedTagError && isset($tags[$e->getTagName()])) {
                $e->setTemplateLine($tags[$e->getTagName()]);
            } elseif ($e instanceof SecurityNotAllowedFilterError && isset($filters[$e->getFilterName()])) {
                $e->setTemplateLine($filters[$e->getFilterName()]);
            } elseif ($e instanceof SecurityNotAllowedFunctionError && isset($functions[$e->getFunctionName()])) {
                $e->setTemplateLine($functions[$e->getFunctionName()]);
            }

            throw $e;
        }

    }
}


/* core/profiles/demo_umami/themes/umami/templates/content/node--card-common.html.twig */
class __TwigTemplate_61de7d040d01854b6f0ca8234ee1873d___260435806 extends Template
{
    private Source $source;
    /**
     * @var array<string, Template>
     */
    private array $macros = [];

    public function __construct(Environment $env)
    {
        parent::__construct($env);

        $this->source = $this->getSourceContext();

        $this->blocks = [
            'title_prefix' => [$this, 'block_title_prefix'],
            'title_suffix' => [$this, 'block_title_suffix'],
        ];
        $this->sandbox = $this->extensions[SandboxExtension::class];
        $this->checkSecurity();
    }

    protected function doGetParent(array $context): bool|string|Template|TemplateWrapper
    {
        // line 90
        return "umami:title";
    }

    protected function doDisplay(array $context, array $blocks = []): iterable
    {
        $macros = $this->macros;
        $this->parent = $this->loadTemplate("umami:title", "core/profiles/demo_umami/themes/umami/templates/content/node--card-common.html.twig", 90);
        yield from $this->parent->unwrap()->yield($context, array_merge($this->blocks, $blocks));
        $this->env->getExtension('\Drupal\Core\Template\TwigExtension')
            ->checkDeprecations($context, ["title_prefix", "title_suffix"]);    }

    // line 96
    /**
     * @return iterable<null|scalar|\Stringable>
     */
    public function block_title_prefix(array $context, array $blocks = []): iterable
    {
        $macros = $this->macros;
        // line 97
        yield "        ";
        yield $this->extensions['Drupal\Core\Template\TwigExtension']->escapeFilter($this->env, ($context["title_prefix"] ?? null), "html", null, true);
        yield "
      ";
        yield from [];
    }

    // line 99
    /**
     * @return iterable<null|scalar|\Stringable>
     */
    public function block_title_suffix(array $context, array $blocks = []): iterable
    {
        $macros = $this->macros;
        // line 100
        yield "        ";
        yield $this->extensions['Drupal\Core\Template\TwigExtension']->escapeFilter($this->env, ($context["title_suffix"] ?? null), "html", null, true);
        yield "
      ";
        yield from [];
    }

    /**
     * @codeCoverageIgnore
     */
    public function getTemplateName(): string
    {
        return "core/profiles/demo_umami/themes/umami/templates/content/node--card-common.html.twig";
    }

    /**
     * @codeCoverageIgnore
     */
    public function isTraitable(): bool
    {
        return false;
    }

    /**
     * @codeCoverageIgnore
     */
    public function getDebugInfo(): array
    {
        return array (  328 => 100,  321 => 99,  313 => 97,  306 => 96,  294 => 90,  201 => 117,  196 => 116,  194 => 107,  193 => 106,  192 => 105,  190 => 103,  188 => 94,  187 => 93,  186 => 92,  185 => 91,  183 => 90,  176 => 89,  164 => 78,  74 => 87,  73 => 86,  72 => 85,  71 => 84,  70 => 83,  69 => 82,  68 => 81,  67 => 80,  66 => 79,  65 => 78,  62 => 77,  58 => 75,  56 => 74,  51 => 72,  49 => 69,  48 => 68,  47 => 67,  46 => 66,  45 => 65,  44 => 63,);
    }

    public function getSourceContext(): Source
    {
        return new Source("", "core/profiles/demo_umami/themes/umami/templates/content/node--card-common.html.twig", "/var/www/html/app/web/core/profiles/demo_umami/themes/umami/templates/content/node--card-common.html.twig");
    }
    
    public function checkSecurity()
    {
        static $tags = array("extends" => 90);
        static $filters = array("escape" => 97);
        static $functions = array();

        try {
            $this->sandbox->checkSecurity(
                ['extends'],
                ['escape'],
                [],
                $this->source
            );
        } catch (SecurityError $e) {
            $e->setSourceContext($this->source);

            if ($e instanceof SecurityNotAllowedTagError && isset($tags[$e->getTagName()])) {
                $e->setTemplateLine($tags[$e->getTagName()]);
            } elseif ($e instanceof SecurityNotAllowedFilterError && isset($filters[$e->getFilterName()])) {
                $e->setTemplateLine($filters[$e->getFilterName()]);
            } elseif ($e instanceof SecurityNotAllowedFunctionError && isset($functions[$e->getFunctionName()])) {
                $e->setTemplateLine($functions[$e->getFunctionName()]);
            }

            throw $e;
        }

    }
}


/* core/profiles/demo_umami/themes/umami/templates/content/node--card-common.html.twig */
class __TwigTemplate_61de7d040d01854b6f0ca8234ee1873d___672496136 extends Template
{
    private Source $source;
    /**
     * @var array<string, Template>
     */
    private array $macros = [];

    public function __construct(Environment $env)
    {
        parent::__construct($env);

        $this->source = $this->getSourceContext();

        $this->blocks = [
            'a11y' => [$this, 'block_a11y'],
            'text' => [$this, 'block_text'],
        ];
        $this->sandbox = $this->extensions[SandboxExtension::class];
        $this->checkSecurity();
    }

    protected function doGetParent(array $context): bool|string|Template|TemplateWrapper
    {
        // line 103
        return "umami:read-more";
    }

    protected function doDisplay(array $context, array $blocks = []): iterable
    {
        $macros = $this->macros;
        $this->parent = $this->loadTemplate("umami:read-more", "core/profiles/demo_umami/themes/umami/templates/content/node--card-common.html.twig", 103);
        yield from $this->parent->unwrap()->yield($context, array_merge($this->blocks, $blocks));
        $this->env->getExtension('\Drupal\Core\Template\TwigExtension')
            ->checkDeprecations($context, ["label", "read_more"]);    }

    // line 109
    /**
     * @return iterable<null|scalar|\Stringable>
     */
    public function block_a11y(array $context, array $blocks = []): iterable
    {
        $macros = $this->macros;
        // line 110
        yield "        ";
        yield $this->extensions['Drupal\Core\Template\TwigExtension']->escapeFilter($this->env, ($context["label"] ?? null), "html", null, true);
        yield "
      ";
        yield from [];
    }

    // line 112
    /**
     * @return iterable<null|scalar|\Stringable>
     */
    public function block_text(array $context, array $blocks = []): iterable
    {
        $macros = $this->macros;
        // line 113
        yield "        ";
        yield $this->extensions['Drupal\Core\Template\TwigExtension']->escapeFilter($this->env, ($context["read_more"] ?? null), "html", null, true);
        yield "
      ";
        yield from [];
    }

    /**
     * @codeCoverageIgnore
     */
    public function getTemplateName(): string
    {
        return "core/profiles/demo_umami/themes/umami/templates/content/node--card-common.html.twig";
    }

    /**
     * @codeCoverageIgnore
     */
    public function isTraitable(): bool
    {
        return false;
    }

    /**
     * @codeCoverageIgnore
     */
    public function getDebugInfo(): array
    {
        return array (  455 => 113,  448 => 112,  440 => 110,  433 => 109,  421 => 103,  328 => 100,  321 => 99,  313 => 97,  306 => 96,  294 => 90,  201 => 117,  196 => 116,  194 => 107,  193 => 106,  192 => 105,  190 => 103,  188 => 94,  187 => 93,  186 => 92,  185 => 91,  183 => 90,  176 => 89,  164 => 78,  74 => 87,  73 => 86,  72 => 85,  71 => 84,  70 => 83,  69 => 82,  68 => 81,  67 => 80,  66 => 79,  65 => 78,  62 => 77,  58 => 75,  56 => 74,  51 => 72,  49 => 69,  48 => 68,  47 => 67,  46 => 66,  45 => 65,  44 => 63,);
    }

    public function getSourceContext(): Source
    {
        return new Source("", "core/profiles/demo_umami/themes/umami/templates/content/node--card-common.html.twig", "/var/www/html/app/web/core/profiles/demo_umami/themes/umami/templates/content/node--card-common.html.twig");
    }
    
    public function checkSecurity()
    {
        static $tags = array("extends" => 103);
        static $filters = array("escape" => 110);
        static $functions = array();

        try {
            $this->sandbox->checkSecurity(
                ['extends'],
                ['escape'],
                [],
                $this->source
            );
        } catch (SecurityError $e) {
            $e->setSourceContext($this->source);

            if ($e instanceof SecurityNotAllowedTagError && isset($tags[$e->getTagName()])) {
                $e->setTemplateLine($tags[$e->getTagName()]);
            } elseif ($e instanceof SecurityNotAllowedFilterError && isset($filters[$e->getFilterName()])) {
                $e->setTemplateLine($filters[$e->getFilterName()]);
            } elseif ($e instanceof SecurityNotAllowedFunctionError && isset($functions[$e->getFunctionName()])) {
                $e->setTemplateLine($functions[$e->getFunctionName()]);
            }

            throw $e;
        }

    }
}
