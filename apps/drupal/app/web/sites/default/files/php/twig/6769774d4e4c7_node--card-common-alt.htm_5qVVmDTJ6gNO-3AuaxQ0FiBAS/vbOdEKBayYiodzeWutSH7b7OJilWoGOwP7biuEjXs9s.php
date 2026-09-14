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

/* core/profiles/demo_umami/themes/umami/templates/content/node--card-common-alt.html.twig */
class __TwigTemplate_f6e09de78e467ec9894a8ea6d6c92d73 extends Template
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
($context["view_mode"] ?? null)) ? (("node--view-mode-" . \Drupal\Component\Utility\Html::getClass(($context["view_mode"] ?? null)))) : ("")), "umami-card--alt"];
        // line 73
        yield $this->extensions['Drupal\Core\Template\TwigExtension']->escapeFilter($this->env, $this->extensions['Drupal\Core\Template\TwigExtension']->attachLibrary("umami/classy.node"), "html", null, true);
        yield "

";
        // line 75
        $context["read_more"] = ('' === $tmp = \Twig\Extension\CoreExtension::captureOutput((function () use (&$context, $macros, $blocks) {
            // line 76
            yield t("View @node.type.entity.label", array("@node.type.entity.label" => CoreExtension::getAttribute($this->env, $this->source, CoreExtension::getAttribute($this->env, $this->source, CoreExtension::getAttribute($this->env, $this->source, ($context["node"] ?? null), "type", [], "any", false, false, true, 76), "entity", [], "any", false, false, true, 76), "label", [], "method", false, false, true, 76), ));
            yield from [];
        })())) ? '' : new Markup($tmp, $this->env->getCharset());
        // line 78
        yield "
";
        // line 79
        yield from $this->loadTemplate("core/profiles/demo_umami/themes/umami/templates/content/node--card-common-alt.html.twig", "core/profiles/demo_umami/themes/umami/templates/content/node--card-common-alt.html.twig", 79, "1015044096")->unwrap()->yield(CoreExtension::toArray(["attributes" => CoreExtension::getAttribute($this->env, $this->source,         // line 80
($context["attributes"] ?? null), "addClass", [($context["classes"] ?? null)], "method", false, false, true, 80), "content" =>         // line 81
($context["content"] ?? null), "content_attributes" =>         // line 82
($context["content_attributes"] ?? null), "label" =>         // line 83
($context["label"] ?? null), "title_attributes" =>         // line 84
($context["title_attributes"] ?? null), "title_prefix" =>         // line 85
($context["title_prefix"] ?? null), "title_suffix" =>         // line 86
($context["title_suffix"] ?? null), "read_more" =>         // line 87
($context["read_more"] ?? null), "url" =>         // line 88
($context["url"] ?? null)]));
        $this->env->getExtension('\Drupal\Core\Template\TwigExtension')
            ->checkDeprecations($context, ["node", "view_mode", "attributes", "content", "content_attributes", "label", "title_attributes", "title_prefix", "title_suffix", "url"]);        yield from [];
    }

    /**
     * @codeCoverageIgnore
     */
    public function getTemplateName(): string
    {
        return "core/profiles/demo_umami/themes/umami/templates/content/node--card-common-alt.html.twig";
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
        return array (  74 => 88,  73 => 87,  72 => 86,  71 => 85,  70 => 84,  69 => 83,  68 => 82,  67 => 81,  66 => 80,  65 => 79,  62 => 78,  58 => 76,  56 => 75,  51 => 73,  49 => 69,  48 => 68,  47 => 67,  46 => 66,  45 => 65,  44 => 63,);
    }

    public function getSourceContext(): Source
    {
        return new Source("", "core/profiles/demo_umami/themes/umami/templates/content/node--card-common-alt.html.twig", "/var/www/html/app/web/core/profiles/demo_umami/themes/umami/templates/content/node--card-common-alt.html.twig");
    }
    
    public function checkSecurity()
    {
        static $tags = array("set" => 63, "trans" => 76, "embed" => 79);
        static $filters = array("clean_class" => 65, "escape" => 73);
        static $functions = array("attach_library" => 73);

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


/* core/profiles/demo_umami/themes/umami/templates/content/node--card-common-alt.html.twig */
class __TwigTemplate_f6e09de78e467ec9894a8ea6d6c92d73___1015044096 extends Template
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
        // line 79
        return "umami:card";
    }

    protected function doDisplay(array $context, array $blocks = []): iterable
    {
        $macros = $this->macros;
        $this->parent = $this->loadTemplate("umami:card", "core/profiles/demo_umami/themes/umami/templates/content/node--card-common-alt.html.twig", 79);
        yield from $this->parent->unwrap()->yield($context, array_merge($this->blocks, $blocks));
        $this->env->getExtension('\Drupal\Core\Template\TwigExtension')
            ->checkDeprecations($context, ["content_attributes", "content", "title_attributes", "label", "title_prefix", "title_suffix", "read_more", "url"]);    }

    // line 90
    /**
     * @return iterable<null|scalar|\Stringable>
     */
    public function block_content(array $context, array $blocks = []): iterable
    {
        $macros = $this->macros;
        // line 91
        yield "    <div";
        yield $this->extensions['Drupal\Core\Template\TwigExtension']->escapeFilter($this->env, CoreExtension::getAttribute($this->env, $this->source, ($context["content_attributes"] ?? null), "addClass", ["umami-card__content"], "method", false, false, true, 91), "html", null, true);
        yield ">
      ";
        // line 92
        yield $this->extensions['Drupal\Core\Template\TwigExtension']->escapeFilter($this->env, ($context["content"] ?? null), "html", null, true);
        yield "
    </div>
    ";
        // line 94
        yield from $this->loadTemplate("core/profiles/demo_umami/themes/umami/templates/content/node--card-common-alt.html.twig", "core/profiles/demo_umami/themes/umami/templates/content/node--card-common-alt.html.twig", 94, "1354456903")->unwrap()->yield(CoreExtension::toArray(["attributes" => CoreExtension::getAttribute($this->env, $this->source,         // line 95
($context["title_attributes"] ?? null), "addClass", ["umami-card__title"], "method", false, false, true, 95), "label" => ((        // line 96
($context["label"] ?? null)) ? (($context["label"] ?? null)) : (CoreExtension::getAttribute($this->env, $this->source, ($context["content"] ?? null), "field_title", [], "any", false, false, true, 96))), "title_prefix" =>         // line 97
($context["title_prefix"] ?? null), "title_suffix" =>         // line 98
($context["title_suffix"] ?? null)]));
        // line 107
        yield "    ";
        yield from $this->loadTemplate("core/profiles/demo_umami/themes/umami/templates/content/node--card-common-alt.html.twig", "core/profiles/demo_umami/themes/umami/templates/content/node--card-common-alt.html.twig", 107, "2004689387")->unwrap()->yield(CoreExtension::toArray(["attributes" => $this->extensions['Drupal\Core\Template\TwigExtension']->createAttribute(["class" => ["umami-card__read-more"]]), "read_more" =>         // line 109
($context["read_more"] ?? null), "label" =>         // line 110
($context["label"] ?? null), "url" =>         // line 111
($context["url"] ?? null)]));
        // line 120
        yield "  ";
        yield from [];
    }

    /**
     * @codeCoverageIgnore
     */
    public function getTemplateName(): string
    {
        return "core/profiles/demo_umami/themes/umami/templates/content/node--card-common-alt.html.twig";
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
        return array (  205 => 120,  203 => 111,  202 => 110,  201 => 109,  199 => 107,  197 => 98,  196 => 97,  195 => 96,  194 => 95,  193 => 94,  188 => 92,  183 => 91,  176 => 90,  164 => 79,  74 => 88,  73 => 87,  72 => 86,  71 => 85,  70 => 84,  69 => 83,  68 => 82,  67 => 81,  66 => 80,  65 => 79,  62 => 78,  58 => 76,  56 => 75,  51 => 73,  49 => 69,  48 => 68,  47 => 67,  46 => 66,  45 => 65,  44 => 63,);
    }

    public function getSourceContext(): Source
    {
        return new Source("", "core/profiles/demo_umami/themes/umami/templates/content/node--card-common-alt.html.twig", "/var/www/html/app/web/core/profiles/demo_umami/themes/umami/templates/content/node--card-common-alt.html.twig");
    }
    
    public function checkSecurity()
    {
        static $tags = array("extends" => 79, "embed" => 94);
        static $filters = array("escape" => 91);
        static $functions = array("create_attribute" => 108);

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


/* core/profiles/demo_umami/themes/umami/templates/content/node--card-common-alt.html.twig */
class __TwigTemplate_f6e09de78e467ec9894a8ea6d6c92d73___1354456903 extends Template
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
        // line 94
        return "umami:title";
    }

    protected function doDisplay(array $context, array $blocks = []): iterable
    {
        $macros = $this->macros;
        $this->parent = $this->loadTemplate("umami:title", "core/profiles/demo_umami/themes/umami/templates/content/node--card-common-alt.html.twig", 94);
        yield from $this->parent->unwrap()->yield($context, array_merge($this->blocks, $blocks));
        $this->env->getExtension('\Drupal\Core\Template\TwigExtension')
            ->checkDeprecations($context, ["title_prefix", "title_suffix"]);    }

    // line 100
    /**
     * @return iterable<null|scalar|\Stringable>
     */
    public function block_title_prefix(array $context, array $blocks = []): iterable
    {
        $macros = $this->macros;
        // line 101
        yield "        ";
        yield $this->extensions['Drupal\Core\Template\TwigExtension']->escapeFilter($this->env, ($context["title_prefix"] ?? null), "html", null, true);
        yield "
      ";
        yield from [];
    }

    // line 103
    /**
     * @return iterable<null|scalar|\Stringable>
     */
    public function block_title_suffix(array $context, array $blocks = []): iterable
    {
        $macros = $this->macros;
        // line 104
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
        return "core/profiles/demo_umami/themes/umami/templates/content/node--card-common-alt.html.twig";
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
        return array (  329 => 104,  322 => 103,  314 => 101,  307 => 100,  295 => 94,  205 => 120,  203 => 111,  202 => 110,  201 => 109,  199 => 107,  197 => 98,  196 => 97,  195 => 96,  194 => 95,  193 => 94,  188 => 92,  183 => 91,  176 => 90,  164 => 79,  74 => 88,  73 => 87,  72 => 86,  71 => 85,  70 => 84,  69 => 83,  68 => 82,  67 => 81,  66 => 80,  65 => 79,  62 => 78,  58 => 76,  56 => 75,  51 => 73,  49 => 69,  48 => 68,  47 => 67,  46 => 66,  45 => 65,  44 => 63,);
    }

    public function getSourceContext(): Source
    {
        return new Source("", "core/profiles/demo_umami/themes/umami/templates/content/node--card-common-alt.html.twig", "/var/www/html/app/web/core/profiles/demo_umami/themes/umami/templates/content/node--card-common-alt.html.twig");
    }
    
    public function checkSecurity()
    {
        static $tags = array("extends" => 94);
        static $filters = array("escape" => 101);
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


/* core/profiles/demo_umami/themes/umami/templates/content/node--card-common-alt.html.twig */
class __TwigTemplate_f6e09de78e467ec9894a8ea6d6c92d73___2004689387 extends Template
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
        // line 107
        return "umami:read-more";
    }

    protected function doDisplay(array $context, array $blocks = []): iterable
    {
        $macros = $this->macros;
        $this->parent = $this->loadTemplate("umami:read-more", "core/profiles/demo_umami/themes/umami/templates/content/node--card-common-alt.html.twig", 107);
        yield from $this->parent->unwrap()->yield($context, array_merge($this->blocks, $blocks));
        $this->env->getExtension('\Drupal\Core\Template\TwigExtension')
            ->checkDeprecations($context, ["label", "read_more"]);    }

    // line 113
    /**
     * @return iterable<null|scalar|\Stringable>
     */
    public function block_a11y(array $context, array $blocks = []): iterable
    {
        $macros = $this->macros;
        // line 114
        yield "        ";
        yield $this->extensions['Drupal\Core\Template\TwigExtension']->escapeFilter($this->env, ($context["label"] ?? null), "html", null, true);
        yield "
      ";
        yield from [];
    }

    // line 116
    /**
     * @return iterable<null|scalar|\Stringable>
     */
    public function block_text(array $context, array $blocks = []): iterable
    {
        $macros = $this->macros;
        // line 117
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
        return "core/profiles/demo_umami/themes/umami/templates/content/node--card-common-alt.html.twig";
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
        return array (  456 => 117,  449 => 116,  441 => 114,  434 => 113,  422 => 107,  329 => 104,  322 => 103,  314 => 101,  307 => 100,  295 => 94,  205 => 120,  203 => 111,  202 => 110,  201 => 109,  199 => 107,  197 => 98,  196 => 97,  195 => 96,  194 => 95,  193 => 94,  188 => 92,  183 => 91,  176 => 90,  164 => 79,  74 => 88,  73 => 87,  72 => 86,  71 => 85,  70 => 84,  69 => 83,  68 => 82,  67 => 81,  66 => 80,  65 => 79,  62 => 78,  58 => 76,  56 => 75,  51 => 73,  49 => 69,  48 => 68,  47 => 67,  46 => 66,  45 => 65,  44 => 63,);
    }

    public function getSourceContext(): Source
    {
        return new Source("", "core/profiles/demo_umami/themes/umami/templates/content/node--card-common-alt.html.twig", "/var/www/html/app/web/core/profiles/demo_umami/themes/umami/templates/content/node--card-common-alt.html.twig");
    }
    
    public function checkSecurity()
    {
        static $tags = array("extends" => 107);
        static $filters = array("escape" => 114);
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
